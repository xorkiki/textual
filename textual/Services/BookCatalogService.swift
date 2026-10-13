import Foundation

/// Shared catalog repository: typed search scopes, provider routing, bounded caches,
/// and cancellation-aware rate limiting. Views do not choose providers or build URLs.
actor BookCatalogService {
    @TaskLocal static var isBackgroundLookup = false
    private var interactiveWaiters = 0
    static let shared = BookCatalogService(session: makeSession())
    static let pageSize = 20
    static let minimumSearchQueryLength = 3

    enum SearchScope: String, CaseIterable, Identifiable, Sendable {
        case all = "All", title = "Title", author = "Author"
        var id: String { rawValue }
    }

    enum Provider: String, Sendable { case google, openLibrary }

    struct SearchPage: Sendable {
        let items: [BookItem]
        let provider: Provider
        let nextOffset: Int?
    }

    private struct SearchKey: Hashable {
        let query: String
        let scope: SearchScope
        let offset: Int
        let provider: Provider
    }

    private struct Cached<Value> {
        let value: Value
        let expiresAt: Date
        var lastAccess: Date = Date()
    }

    private let session: URLSession
    private let apiKey: String?
    var hasGoogleAPIKey: Bool { apiKey != nil }
    private let minimumRequestInterval: TimeInterval
    private var lastCatalogRequestStarted = Date.distantPast
    private var googleRetryAfter = Date.distantPast
    private var searches: [SearchKey: Cached<SearchPage>] = [:]
    private var details: [String: Cached<BookItem>] = [:]
    private var workEditionSubjects: [String: Cached<[String]>] = [:]
    private var workEditionPages: [String: Cached<[Int]>] = [:]
    private struct CoverLookupKey: Hashable {
        let book: BookCoverIdentity
        let provider: Provider
    }
    private var coverLookups: [CoverLookupKey: Cached<[String]>] = [:]

    init(session: URLSession = .shared, apiKey: String? = Secrets.googleBooksAPIKey,
         minimumRequestInterval: TimeInterval = 1) {
        self.session = session
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.apiKey = key.isEmpty || key.contains("$(") ? nil : key
        self.minimumRequestInterval = max(0, minimumRequestInterval)
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024,
                                           diskCapacity: 50 * 1024 * 1024,
                                           diskPath: "kiki.textual.catalog")
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }

    struct SearchResult: Codable, Sendable {
        let items: [BookItem]?
        let totalItems: Int?
    }

    /// Response from volumes/{id} endpoint - single volume
    struct VolumeResponse: Codable, Sendable {
        let id: String?
        let volumeInfo: VolumeInfo?
    }

    struct BookItem: Codable, Sendable {
        let id: String?
        let volumeInfo: VolumeInfo?

        enum CodingKeys: String, CodingKey {
            case id
            case volumeInfo
        }
    }

    struct VolumeInfo: Codable, Sendable {
        let title: String?
        let subtitle: String?
        let authors: [String]?
        let description: String?
        let industryIdentifiers: [IndustryIdentifier]?
        let imageLinks: ImageLinks?
        let averageRating: Double?
        let ratingsCount: Int?
        let categories: [String]?
        var pageCount: Int? = nil
        var mainCategory: String? = nil

        var catalogCategories: [String] {
            Array(Set((categories ?? []) + [mainCategory].compactMap { $0 })).sorted()
        }

        enum CodingKeys: String, CodingKey {
            case title
            case subtitle
            case authors
            case description
            case industryIdentifiers
            case imageLinks
            case averageRating
            case ratingsCount
            case categories
            case pageCount
            case mainCategory
        }

        struct IndustryIdentifier: Codable, Sendable {
            let type: String?
            let identifier: String?

            enum CodingKeys: String, CodingKey {
                case type
                case identifier
            }
        }

        struct ImageLinks: Codable, Sendable {
            let thumbnail: String?
            let smallThumbnail: String?

            enum CodingKeys: String, CodingKey {
                case thumbnail
                case smallThumbnail
            }
        }
    }

    func searchBooks(query: String, scope: SearchScope = .all, startIndex: Int = 0) async throws -> [BookItem] {
        try await searchPage(query: query, scope: scope, startIndex: startIndex).items
    }

    func searchPage(query: String, scope: SearchScope = .all, startIndex: Int = 0,
                    provider: Provider? = nil) async throws -> SearchPage {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = provider ?? (apiKey != nil && Date() >= googleRetryAfter ? .google : .openLibrary)
        guard !query.isEmpty else { return SearchPage(items: [], provider: selected, nextOffset: nil) }
        guard query.count >= Self.minimumSearchQueryLength else { throw ServiceError.queryTooShort }
        try Task.checkCancellation()
        let offset = max(0, startIndex)
        let key = SearchKey(query: query.lowercased(), scope: scope, offset: offset, provider: selected)
        if let cached = cachedSearch(for: key) { return cached }

        let page: SearchPage
        switch selected {
        case .google:
            do {
                page = try await googlePage(query: query, scope: scope, offset: offset)
            } catch let error as ServiceError where error.canUseFallback {
                try Task.checkCancellation()
                // Do not keep paying the latency of a provider known to be unavailable.
                googleRetryAfter = Date().addingTimeInterval(300)
                // Keep pagination on its original provider, but cool down future searches.
                guard provider == nil && offset == 0 else { throw error }
                return try await searchPage(query: query, scope: scope, provider: .openLibrary)
            }
        case .openLibrary:
            page = try await openLibraryPage(query: query, scope: scope, offset: offset)
        }
        try Task.checkCancellation()
        searches[key] = Cached(value: page, expiresAt: Date().addingTimeInterval(300))
        trim(&searches, limit: 64)
        return page
    }

    private func cachedSearch(for key: SearchKey) -> SearchPage? {
        guard var entry = searches[key], entry.expiresAt > Date() else {
            searches.removeValue(forKey: key)
            return nil
        }
        entry.lastAccess = Date()
        searches[key] = entry
        return entry.value
    }

    private func googlePage(query: String, scope: SearchScope, offset: Int) async throws -> SearchPage {
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let term: String
        switch scope {
        case .all: term = query
        case .title: term = "intitle:\"\(escaped)\""
        case .author: term = "inauthor:\"\(escaped)\""
        }
        let url = try googleURL(queryItems: [
            URLQueryItem(name: "q", value: term),
            URLQueryItem(name: "maxResults", value: String(Self.pageSize)),
            URLQueryItem(name: "startIndex", value: String(offset)),
            URLQueryItem(name: "printType", value: "books")
        ])
        let response: SearchResult = try await request(url)
        let items = response.items ?? []
        return SearchPage(items: uniqueValidItems(items), provider: .google,
                          nextOffset: nextOffset(offset: offset, count: items.count, total: response.totalItems))
    }

    private func openLibraryPage(query: String, scope: SearchScope, offset: Int) async throws -> SearchPage {
        let field: String
        switch scope { case .all: field = "q"; case .title: field = "title"; case .author: field = "author" }
        let url = try makeURL("https://openlibrary.org/search.json", queryItems: [
            URLQueryItem(name: field, value: query),
            URLQueryItem(name: "limit", value: String(Self.pageSize)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "fields", value: "key,title,author_name,cover_i,subject")
        ])
        let response: OpenLibrarySearch = try await request(url, catalog: true)
        let items = response.docs.compactMap { document -> BookItem? in
            let workID = document.key.components(separatedBy: "/").last ?? ""
            guard workID.range(of: "^OL[0-9]+W$", options: .regularExpression) != nil else { return nil }
            let cover = document.cover_i.flatMap { $0 > 0 ? Self.catalogCover($0) : nil }
            return BookItem(id: "openlibrary:\(workID)", volumeInfo: VolumeInfo(
                title: document.title, subtitle: nil, authors: document.author_name,
                description: nil, industryIdentifiers: nil,
                imageLinks: cover.map { .init(thumbnail: $0, smallThumbnail: nil) },
                averageRating: nil, ratingsCount: nil, categories: document.subject
            ))
        }
        return SearchPage(items: uniqueValidItems(items), provider: .openLibrary,
                          nextOffset: nextOffset(offset: offset, count: response.docs.count,
                                                 total: response.numFound ?? response.num_found))
    }

    private func nextOffset(offset: Int, count: Int, total: Int?) -> Int? {
        guard count > 0 else { return nil }
        let next = offset + count
        if let total { return next < total ? next : nil }
        return count == Self.pageSize ? next : nil
    }

    func searchBookId(isbn: String) async throws -> String? {
        try await searchBooks(query: "isbn:\(isbn)").first?.id
    }

    struct ClassificationEvidence: Codable, Sendable {
        let categories: [String]
        let source: String
        var editionPages: Int? = nil
        var editionISBN: String? = nil
        // Keep source boundaries: arbitrary Open Library subjects are not Google genres.
        var openLibraryCategories: [String]? = nil
        /// Text from identity-verified catalog records, used only for estimates.
        var context: [String]? = nil
        var workPageCounts: [Int]? = nil

        var genres: Set<String> {
            GenreTaxonomy.normalized(categories, isOpenLibrary: source == "openlibrary")
                .union(GenreTaxonomy.normalized(openLibraryCategories ?? [], isOpenLibrary: true))
        }
        var fictionKind: BookFictionKind? {
            BookFictionKind.classify(categories) ?? BookFictionKind.classify(openLibraryCategories ?? [])
        }
        // Audience or identity labels alone do not finish genre enrichment.
        var isComplete: Bool {
            !genres.subtracting(["Young adult", "Middle grade", "Children’s", "LGBTQIA+"]).isEmpty && fictionKind != nil
        }

        func supplemented(with other: Self) -> Self {
            if let a = fictionKind, let b = other.fictionKind, a != b { return self }
            if source == "openlibrary", other.source == "google" {
                return other.supplemented(with: self)
            }
            var result = self
            if other.source == "openlibrary" {
                result.openLibraryCategories = Array(Set((openLibraryCategories ?? []) + other.categories + (other.openLibraryCategories ?? []))).sorted()
            } else if source == "google" {
                result = Self(categories: Array(Set(categories + other.categories)).sorted(), source: source,
                              editionPages: editionPages ?? other.editionPages, editionISBN: editionISBN ?? other.editionISBN,
                              openLibraryCategories: openLibraryCategories)
            }
            result.context = Array(Set((context ?? []) + (other.context ?? []))).sorted()
            result.workPageCounts = Array(Set((workPageCounts ?? []) + (other.workPageCounts ?? []))).sorted()
            return result
        }
    }

    nonisolated static func classificationContext(_ item: BookItem) -> [String] {
        [item.volumeInfo?.subtitle, item.volumeInfo?.description].compactMap { value in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return String(value.prefix(12_000))
        }
    }

    struct ClassificationLookup: Sendable {
        let evidence: ClassificationEvidence?
        let retryRequired: Bool
        let usedGoogleKey: Bool
    }

    func classification(isbn: String, title: String, author: String,
                        savedCategories: [String], savedSource: String) async throws -> ClassificationEvidence? {
        try await classificationLookup(isbn: isbn, title: title, author: author,
            savedCategories: savedCategories, savedSource: savedSource).evidence
    }

    /// Search identifies candidates; detail records and ISBN-linked editions supply
    /// classification. An unavailable provider is not a successful negative lookup.
    func classificationLookup(isbn: String, title: String, author: String,
                              savedCategories: [String], savedSource: String) async throws -> ClassificationLookup {
        let normalizedISBN = StoryGraphImporter.normalizedISBN(isbn)
        var best: ClassificationEvidence?
        var hadFailure = false
        var googleSucceeded = false
        var googleFailed = Date() < googleRetryAfter
        var visitedGoogleIDs = Set<String>()
        func merge(_ evidence: ClassificationEvidence?) {
            guard let evidence else { return }
            best = best.map { $0.supplemented(with: evidence) } ?? evidence
        }
        func outcome() -> ClassificationLookup {
            ClassificationLookup(evidence: best,
                retryRequired: (hadFailure || googleFailed) && best?.isComplete != true,
                usedGoogleKey: apiKey != nil && googleSucceeded && !googleFailed)
        }
        func recordGoogleFailure(_ error: Error) {
            hadFailure = true
            googleFailed = true
            if case ServiceError.httpStatus(let status) = error, [401, 403, 429].contains(status) {
                googleRetryAfter = Date().addingTimeInterval(300)
            }
        }
        var queries: [(String, Bool)] = []
        if let normalizedISBN { queries.append(("isbn:\(normalizedISBN)", true)) }
        if !Self.classificationTitle(title).isEmpty, !Self.matchKey(author).isEmpty {
            queries.append(("\(Self.classificationTitle(title)) \(author)", false))
        }
        for (query, requireISBN) in queries {
            try Task.checkCancellation()
            guard Date() >= googleRetryAfter else { break }
            do {
                let page = try await googleClassificationSearch(query)
                googleSucceeded = true
                merge(Self.classificationEvidence(page, isbn: normalizedISBN, title: title, author: author, requireISBN: requireISBN))
                // Search often returns only "Fiction" or an audience label. Read
                // up to three verified volume records before discarding the source.
                let candidates = page.filter {
                    Self.isClassificationMatch($0, isbn: normalizedISBN, title: title, author: author, requireISBN: requireISBN)
                }
                let candidateKinds = Set(candidates.compactMap { BookFictionKind.classify($0.volumeInfo?.catalogCategories ?? []) })
                if candidateKinds.count <= 1,
                   best?.isComplete != true || best?.categories.contains(where: { $0.contains("/") }) != true {
                    for candidate in candidates {
                        guard visitedGoogleIDs.count < 3 else { break }
                        guard let id = candidate.id, !id.isEmpty, visitedGoogleIDs.insert(id).inserted else { continue }
                        do {
                            let detail = try await fetchVolume(id: id)
                            // The ID came from a verified candidate. Accept missing
                            // identity fields in details, but reject contradictory ones.
                            if Self.detailMatches(detail, candidate: candidate) {
                                let categories = detail.volumeInfo?.catalogCategories ?? []
                                let context = Self.classificationContext(detail)
                                if !categories.isEmpty || !context.isEmpty {
                                    merge(ClassificationEvidence(categories: categories, source: "google", context: context, workPageCounts: detail.volumeInfo?.pageCount.map { [$0] }))
                                }
                            }
                        } catch is CancellationError { throw CancellationError() }
                        catch ServiceError.notFound { continue }
                        catch {
                            recordGoogleFailure(error)
                            if Date() < googleRetryAfter { break }
                        }
                        if best?.isComplete == true { break }
                    }
                }
                if best?.isComplete == true { return outcome() }
            } catch is CancellationError { throw CancellationError() }
            catch { recordGoogleFailure(error) }
        }
        try Task.checkCancellation()
        if !savedCategories.isEmpty {
            merge(ClassificationEvidence(categories: savedCategories, source: savedSource))
            if best?.isComplete == true { return outcome() }
        }

        // The exact edition's link verifies the work independently of translated
        // titles, subtitles, initials, narrator credits, and search ranking.
        var visitedWorkIDs = Set<String>()
        if let normalizedISBN {
            do {
                let url = try makeURL("https://openlibrary.org/isbn/\(normalizedISBN).json")
                let edition: OpenLibraryEdition = try await request(url, catalog: true)
                let identifiers = (edition.isbn_10 ?? []) + (edition.isbn_13 ?? [])
                if identifiers.contains(where: { StoryGraphImporter.normalizedISBN($0) == normalizedISBN }) {
                    if let subjects = edition.subjects, !subjects.isEmpty {
                        merge(ClassificationEvidence(categories: subjects, source: "openlibrary"))
                    }
                    for work in (edition.works ?? []).prefix(3) {
                        let id = work.key.components(separatedBy: "/").last ?? ""
                        guard id.range(of: "^OL[0-9]+W$", options: .regularExpression) != nil,
                              visitedWorkIDs.insert(id).inserted else { continue }
                        do {
                            let item = try await fetchVolume(id: "openlibrary:" + id)
                            let categories = item.volumeInfo?.catalogCategories ?? []
                            let context = Self.classificationContext(item)
                            if !categories.isEmpty || !context.isEmpty {
                                merge(ClassificationEvidence(categories: categories, source: "openlibrary", context: context))
                            }
                            if best?.isComplete != true {
                                merge(try await classificationFromLinkedEditions(workID: id))
                            }
                        } catch is CancellationError { throw CancellationError() }
                        catch ServiceError.notFound { continue }
                        catch { hadFailure = true }
                    }
                    if let pages = edition.number_of_pages, pages > 0, best != nil {
                        best?.editionPages = pages
                        best?.editionISBN = normalizedISBN
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch ServiceError.notFound { /* A missing edition is a normal miss. */ }
            catch { hadFailure = true }
            if best?.isComplete == true { return outcome() }
        }

        guard !Self.classificationTitle(title).isEmpty, !Self.matchKey(author).isEmpty else { return outcome() }
        let query = "title:\"\(Self.classificationTitle(title))\" author:\"\(author.replacingOccurrences(of: "\"", with: ""))\""
        let page: SearchPage
        do { page = try await searchPage(query: query, provider: .openLibrary) }
        catch is CancellationError { throw CancellationError() }
        catch { hadFailure = true; return outcome() }
        var evidence: [ClassificationEvidence] = []
        for candidate in page.items.filter({ Self.matchesWork($0, title: title, author: author) }).prefix(3) {
            var categories = candidate.volumeInfo?.catalogCategories ?? []
            var context = Self.classificationContext(candidate)
            if let id = candidate.id,
               visitedWorkIDs.insert(String(id.dropFirst("openlibrary:".count))).inserted {
                do {
                    let item = try await fetchVolume(id: id)
                    categories += item.volumeInfo?.catalogCategories ?? []
                    context += Self.classificationContext(item)
                    if !ClassificationEvidence(categories: categories, source: "openlibrary").isComplete,
                       let editionEvidence = try await classificationFromLinkedEditions(
                        workID: String(id.dropFirst("openlibrary:".count))) {
                        categories += editionEvidence.categories
                    }
                } catch is CancellationError { throw CancellationError() }
                catch ServiceError.notFound { /* Retain the verified search subjects. */ }
                catch { hadFailure = true }
            }
            if !categories.isEmpty || !context.isEmpty {
                evidence.append(ClassificationEvidence(categories: Array(Set(categories)).sorted(), source: "openlibrary", context: Array(Set(context)).sorted()))
            }
        }
        let kinds = Set(evidence.compactMap(\.fictionKind))
        if kinds.count <= 1 { for item in evidence { merge(item) } }
        return outcome()
    }

    /// Work subjects and edition subjects are independently populated in Open
    /// Library. A sparse work can still have well-classified sibling editions.
    /// Work membership verifies identity; another edition never supplies pages.
    private func classificationFromLinkedEditions(workID: String) async throws -> ClassificationEvidence? {
        guard workID.range(of: "^OL[0-9]+W$", options: .regularExpression) != nil else {
            throw ServiceError.invalidURL
        }
        let categories: [String]
        if var cached = workEditionSubjects[workID], cached.expiresAt > Date() {
            cached.lastAccess = Date()
            workEditionSubjects[workID] = cached
            categories = cached.value
        } else {
            // One bounded page, used only when the work's classification is sparse.
            let url = try makeURL("https://openlibrary.org/works/\(workID)/editions.json",
                                  queryItems: [URLQueryItem(name: "limit", value: "20")])
            let response: OpenLibraryEditions = try await request(url, catalog: true)
            let subjects = response.entries.prefix(20).filter {
                $0.works?.contains { $0.key == "/works/" + workID } == true
            }.map { $0.subjects ?? [] }
            let kinds = Set(subjects.compactMap(BookFictionKind.classify))
            // Conflicting catalog editions are not resolved by picking one.
            categories = kinds.count <= 1 ? Array(Set(subjects.flatMap { $0 })).sorted() : []
            workEditionSubjects[workID] = Cached(value: categories, expiresAt: Date().addingTimeInterval(86_400))
            trim(&workEditionSubjects, limit: 64)
        }
        return categories.isEmpty ? nil : ClassificationEvidence(categories: categories, source: "openlibrary")
    }

    private struct OpenLibraryEditions: Decodable {
        let entries: [OpenLibraryEdition]
    }

    private struct OpenLibraryEdition: Decodable {
        let isbn_10: [String]?
        let isbn_13: [String]?
        let subjects: [String]?
        let number_of_pages: Int?
        let works: [WorkLink]?
        struct WorkLink: Decodable { let key: String }
    }

    nonisolated private static func detailMatches(_ detail: BookItem, candidate: BookItem) -> Bool {
        if let id = detail.id, let expected = candidate.id, id != expected { return false }
        guard let info = detail.volumeInfo else { return false }
        // A matching ISBN is stronger than title spelling differences.
        let expectedISBNs = Set((candidate.volumeInfo?.industryIdentifiers ?? []).compactMap {
            StoryGraphImporter.normalizedISBN($0.identifier ?? "")
        })
        let foundISBNs = Set((info.industryIdentifiers ?? []).compactMap {
            StoryGraphImporter.normalizedISBN($0.identifier ?? "")
        })
        if !expectedISBNs.isDisjoint(with: foundISBNs) { return true }
        if let title = info.title, let expected = candidate.volumeInfo?.title,
           matchKey(classificationTitle(title)) != matchKey(classificationTitle(expected)) { return false }
        if let authors = info.authors, !authors.isEmpty,
           let expected = candidate.volumeInfo?.authors, !expected.isEmpty,
           !authors.contains(where: { a in expected.contains { authorKey(a) == authorKey($0) } }) { return false }
        return true
    }

    private func googleClassificationSearch(_ query: String) async throws -> [BookItem] {
        let url = try googleURL(queryItems: [URLQueryItem(name: "q", value: query),
                                             URLQueryItem(name: "maxResults", value: "10")])
        let response: SearchResult = try await request(url, catalog: true)
        return response.items ?? []
    }

    nonisolated static func classificationTitle(_ title: String) -> String {
        title.replacingOccurrences(of: #"\s*\[Dramatized[^\]]*\]"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s*\([0-9]+ of [0-9]+\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\([^)]*#[0-9][^)]*\)$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func matchKey(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    nonisolated private static func authorKey(_ text: String) -> String {
        // J.R.R. and J. R. R. share an identity; a different given name does not.
        var words: [String] = []
        var initials = ""
        for token in matchKey(text).split(separator: " ") {
            if token.count == 1 { initials += token }
            else {
                if !initials.isEmpty { words.append(initials); initials = "" }
                words.append(String(token))
            }
        }
        if !initials.isEmpty { words.append(initials) }
        return words.joined(separator: " ")
    }

    nonisolated private static func isClassificationMatch(_ item: BookItem, isbn: String?, title: String,
                                                          author: String, requireISBN: Bool) -> Bool {
        if requireISBN {
            guard let isbn = isbn.flatMap(StoryGraphImporter.normalizedISBN) else { return false }
            return item.volumeInfo?.industryIdentifiers?.contains {
                StoryGraphImporter.normalizedISBN($0.identifier ?? "") == isbn
            } == true
        }
        return matchesWork(item, title: title, author: author)
    }

    nonisolated static func matchesWork(_ item: BookItem, title: String, author: String) -> Bool {
        guard let info = item.volumeInfo, let candidateTitle = info.title else { return false }
        let expected = matchKey(classificationTitle(title))
        let authors = author.components(separatedBy: ",").map(authorKey).filter { !$0.isEmpty }
        let fullTitle = candidateTitle + (info.subtitle.map { ": " + $0 } ?? "")
        let titleMatches = [candidateTitle, fullTitle].contains { matchKey(classificationTitle($0)) == expected }
        return !expected.isEmpty && titleMatches
            && (info.authors ?? []).contains { authors.contains(authorKey($0)) }
    }

    nonisolated static func classificationEvidence(_ items: [BookItem], isbn: String?, title: String,
                                                   author: String, requireISBN: Bool) -> ClassificationEvidence? {
        let candidates = items.filter {
            isClassificationMatch($0, isbn: isbn, title: title, author: author, requireISBN: requireISBN)
        }
        let categories = Array(Set(candidates.flatMap { $0.volumeInfo?.catalogCategories ?? [] })).sorted()
        let context = Array(Set(candidates.flatMap(Self.classificationContext))).sorted()
        guard !categories.isEmpty || !context.isEmpty else { return nil }
        let kinds = Set(candidates.compactMap { BookFictionKind.classify($0.volumeInfo?.catalogCategories ?? []) })
        // Conflicting editions are not a reliable category source.
        guard kinds.count <= 1 else { return nil }
        let normalizedISBN = isbn.flatMap(StoryGraphImporter.normalizedISBN)
        let pages = normalizedISBN.flatMap { exactEditionPageCount(items: candidates, isbn: $0) }
        return ClassificationEvidence(categories: categories, source: "google", editionPages: pages,
                                      editionISBN: pages == nil ? nil : normalizedISBN, context: context,
                                      workPageCounts: candidates.compactMap { $0.volumeInfo?.pageCount }.filter { (1...20_000).contains($0) })
    }

    /// Same-work edition lengths are explicitly estimates. Identity checks are
    /// the same as classification; an unrelated search hit never supplies a count.
    func estimatedPageCounts(isbn: String, title: String, author: String) async throws -> [Int] {
        var visited = Set<String>()
        if let isbn = StoryGraphImporter.normalizedISBN(isbn) {
            do {
                let edition: OpenLibraryEdition = try await request(makeURL("https://openlibrary.org/isbn/\(isbn).json"), catalog: true)
                if ((edition.isbn_10 ?? []) + (edition.isbn_13 ?? [])).contains(where: { StoryGraphImporter.normalizedISBN($0) == isbn }) {
                    for link in (edition.works ?? []).prefix(2) {
                        let id = link.key.components(separatedBy: "/").last ?? ""
                        guard id.range(of: "^OL[0-9]+W$", options: .regularExpression) != nil else { continue }
                        visited.insert(id)
                        let counts = try await linkedEditionPageCounts(workID: id)
                        if !counts.isEmpty { return counts }
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { /* Missing or temporarily unavailable editions can use work search. */ }
        }
        try Task.checkCancellation()
        guard !Self.classificationTitle(title).isEmpty, !Self.matchKey(author).isEmpty else { return [] }
        if Date() >= googleRetryAfter {
            do {
                let items = try await googleClassificationSearch("\(Self.classificationTitle(title)) \(author)")
                let matches = items.filter { Self.matchesWork($0, title: title, author: author) }
                let kinds = Set(matches.compactMap { BookFictionKind.classify($0.volumeInfo?.catalogCategories ?? []) })
                let counts = matches.compactMap { $0.volumeInfo?.pageCount }.filter { (1...20_000).contains($0) }
                if kinds.count <= 1 && !counts.isEmpty { return counts }
            } catch is CancellationError { throw CancellationError() }
            catch { /* Open Library can still supply a verified work. */ }
        }
        do {
            let query = "title:\"\(Self.classificationTitle(title))\" author:\"\(author.replacingOccurrences(of: "\"", with: ""))\""
            let page = try await searchPage(query: query, provider: .openLibrary)
            for item in page.items.filter({ Self.matchesWork($0, title: title, author: author) }).prefix(2) {
                guard let key = item.id, key.hasPrefix("openlibrary:") else { continue }
                let id = String(key.dropFirst("openlibrary:".count))
                guard visited.insert(id).inserted else { continue }
                let counts = try await linkedEditionPageCounts(workID: id)
                if !counts.isEmpty { return counts }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { /* The display fallback remains marked low confidence. */ }
        return []
    }

    private func linkedEditionPageCounts(workID: String) async throws -> [Int] {
        guard workID.range(of: "^OL[0-9]+W$", options: .regularExpression) != nil else { return [] }
        if let cached = workEditionPages[workID], cached.expiresAt > Date() { return cached.value }
        let url = try makeURL("https://openlibrary.org/works/\(workID)/editions.json", queryItems: [URLQueryItem(name: "limit", value: "20")])
        let response: OpenLibraryEditions = try await request(url, catalog: true)
        let linked = response.entries.prefix(20).filter { $0.works?.contains { $0.key == "/works/" + workID } == true }
        let kinds = Set(linked.compactMap { BookFictionKind.classify($0.subjects ?? []) })
        let counts = kinds.count <= 1 ? linked.compactMap(\.number_of_pages).filter { (1...20_000).contains($0) } : []
        workEditionPages[workID] = Cached(value: counts, expiresAt: Date().addingTimeInterval(86_400))
        trim(&workEditionPages, limit: 64)
        return counts
    }

    /// Page totals always require the imported edition's exact ISBN, including
    /// results found through a broader title/author search.
    func editionPageCount(isbn: String, title: String = "", author: String = "") async throws -> Int? {
        guard let isbn = StoryGraphImporter.normalizedISBN(isbn) else { return nil }
        struct Edition: Decodable { let number_of_pages: Int? }
        let url = try makeURL("https://openlibrary.org/isbn/\(isbn).json")
        if let edition: Edition = try? await request(url, catalog: true),
           let count = edition.number_of_pages, count > 0 { return count }
        try Task.checkCancellation()
        guard Date() >= googleRetryAfter else { return nil }
        if let items = try? await googleClassificationSearch("isbn:\(isbn)"),
           let pages = Self.exactEditionPageCount(items: items, isbn: isbn) { return pages }
        try Task.checkCancellation()
        guard !title.isEmpty, !author.isEmpty else { return nil }
        let items = try await googleClassificationSearch("\(Self.classificationTitle(title)) \(author)")
        return Self.exactEditionPageCount(items: items, isbn: isbn)
    }

    nonisolated static func exactEditionPageCount(items: [BookItem], isbn: String) -> Int? {
        guard let isbn = StoryGraphImporter.normalizedISBN(isbn) else { return nil }
        let counts = Set(items.compactMap { item -> Int? in
            guard item.volumeInfo?.industryIdentifiers?.contains(where: {
                StoryGraphImporter.normalizedISBN($0.identifier ?? "") == isbn
            }) == true, let count = item.volumeInfo?.pageCount, count > 0 else { return nil }
            return count
        })
        return counts.count == 1 ? counts.first : nil
    }

    /// Imports without ISBNs still resolve by a verified title-and-author match.
    /// Returns work metadata without changing the saved edition or import identity.
    func matchedBook(title: String, author: String, forceRefresh: Bool = false) async throws -> BookItem? {
        let title = Self.classificationTitle(title)
        let author = author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !author.isEmpty, author.lowercased() != "unknown author" else { return nil }
        let query = "\(title) \(author)"
        // Share the cover search cache, so tapping a recovered cover only needs
        // its detail record. The secondary provider is only tried after a miss.
        var candidates: [BookItem] = []
        var lookupError: Error?
        do {
            let page = try await searchPage(query: query, provider: .openLibrary)
            candidates = page.items.filter { Self.matchesWork($0, title: title, author: author) }
        } catch { lookupError = error }
        try Task.checkCancellation()
        if candidates.isEmpty, apiKey != nil, Date() >= googleRetryAfter {
            let page = try await searchPage(query: query, provider: .google)
            candidates = page.items.filter { Self.matchesWork($0, title: title, author: author) }
            lookupError = nil
        }
        if candidates.isEmpty, let lookupError { throw lookupError }
        guard let candidate = candidates.first, let id = candidate.id else { return nil }
        let matched = try await fetchVolume(id: id, forceRefresh: forceRefresh)
        var info = matched.volumeInfo
        // Title/author identifies a work, not the imported edition's page count.
        info?.pageCount = nil
        return BookItem(id: matched.id, volumeInfo: info)
    }

    /// One provider per stage: return candidates immediately so images can load
    /// before paying for a secondary catalog. Empty results are cached too.
    func replacementCoverURLs(for book: BookCoverIdentity, provider: Provider = .openLibrary) async throws -> [String] {
        try Task.checkCancellation()
        let key = CoverLookupKey(book: book, provider: provider)
        if var cached = coverLookups[key], cached.expiresAt > Date() {
            cached.lastAccess = Date()
            coverLookups[key] = cached
            return cached.value
        }
        if provider == .google, apiKey == nil || Date() < googleRetryAfter { return [] }
        let title = Self.classificationTitle(book.title)
        let author = book.author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !author.isEmpty, author.lowercased() != "unknown author" else { return [] }
        var urls: [String] = []
        var hadFailure = false
        do {
            let page = try await searchPage(query: "\(title) \(author)", provider: provider)
            for item in page.items.filter({ Self.matchesWork($0, title: book.title, author: author) }).prefix(3) {
                for value in [item.volumeInfo?.imageLinks?.thumbnail, item.volumeInfo?.imageLinks?.smallThumbnail] {
                    if let value, let url = BookCoverURL.normalized(value), !urls.contains(url) { urls.append(url) }
                }
            }
        } catch { hadFailure = true }
        try Task.checkCancellation()
        coverLookups[key] = Cached(value: urls, expiresAt: Date().addingTimeInterval(hadFailure ? 30 : (urls.isEmpty ? 300 : 3600)))
        trim(&coverLookups, limit: 128)
        return urls
    }

    /// Source-prefixed IDs keep existing Google and Open Library books compatible.
    func fetchVolume(id: String, forceRefresh: Bool = false) async throws -> BookItem {
        try Task.checkCancellation()
        if !forceRefresh, var entry = details[id], entry.expiresAt > Date() {
            entry.lastAccess = Date()
            details[id] = entry
            return entry.value
        }
        let item: BookItem
        if id.hasPrefix("openlibrary:") {
            let workID = String(id.dropFirst("openlibrary:".count))
            guard workID.range(of: "^OL[0-9]+W$", options: .regularExpression) != nil else {
                throw ServiceError.invalidURL
            }
            let url = try makeURL("https://openlibrary.org/works/\(workID).json")
            let work: OpenLibraryWork = try await request(url, catalog: true, forceRefresh: forceRefresh)
            let cover = work.covers?.first(where: { $0 > 0 }).map(Self.catalogCover)
            item = BookItem(id: id, volumeInfo: VolumeInfo(
                title: work.title, subtitle: nil, authors: nil,
                description: work.description?.value, industryIdentifiers: nil,
                imageLinks: cover.map { .init(thumbnail: $0, smallThumbnail: nil) },
                averageRating: nil, ratingsCount: nil, categories: work.subjects
            ))
        } else {
            guard !id.isEmpty, !id.contains("/"), !id.contains("?"), !id.contains("#") else {
                throw ServiceError.invalidURL
            }
            let url = try googleURL(path: "/\(id)")
            let response: VolumeResponse = try await request(url, forceRefresh: forceRefresh)
            item = BookItem(id: response.id ?? id, volumeInfo: response.volumeInfo)
        }
        try Task.checkCancellation()
        details[id] = Cached(value: item, expiresAt: Date().addingTimeInterval(86_400))
        trim(&details, limit: 64)
        return item
    }

    private func trim<Key, Value>(_ cache: inout [Key: Cached<Value>], limit: Int) {
        let now = Date()
        cache = cache.filter { $0.value.expiresAt > now }
        while cache.count > limit, let oldest = cache.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            cache.removeValue(forKey: oldest)
        }
    }

    private func uniqueValidItems(_ items: [BookItem]) -> [BookItem] {
        var seen = Set<String>()
        return items.filter {
            guard let id = $0.id, !id.isEmpty,
                  let title = $0.volumeInfo?.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            return seen.insert(id).inserted
        }
    }

    private func googleURL(path: String = "", queryItems: [URLQueryItem] = []) throws -> URL {
        var items = queryItems
        if let apiKey { items.append(URLQueryItem(name: "key", value: apiKey)) }
        return try makeURL("https://www.googleapis.com/books/v1/volumes" + path, queryItems: items)
    }

    private func makeURL(_ base: String, queryItems: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(string: base) else { throw ServiceError.invalidURL }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw ServiceError.invalidURL }
        return url
    }

    private func acquireCatalogSlot() async throws {
        let background = Self.isBackgroundLookup
        if !background { interactiveWaiters += 1 }
        defer { if !background { interactiveWaiters -= 1 } }
        while true {
            try Task.checkCancellation()
            let delay = minimumRequestInterval - Date().timeIntervalSince(lastCatalogRequestStarted)
            if delay <= 0, !background || interactiveWaiters == 0 {
                lastCatalogRequestStarted = Date()
                return
            }
            // A canceled waiter never reserves time. Recheck after actor reentry.
            try await Task.sleep(nanoseconds: UInt64(max(0.05, delay) * 1_000_000_000))
        }
    }

    private func request<Response: Decodable>(_ url: URL, catalog: Bool = false,
                                               forceRefresh: Bool = false) async throws -> Response {
        if catalog || Self.isBackgroundLookup { try await acquireCatalogSlot() }
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if forceRefresh { request.cachePolicy = .reloadIgnoringLocalCacheData }
        if url.host == "www.googleapis.com", let bundleID = Bundle.main.bundleIdentifier {
            request.setValue(bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        }
        request.setValue("Textual/1.0 (https://github.com/xorkiki/textual)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        guard response.statusCode == 200 else {
            if response.statusCode == 404 { throw ServiceError.notFound }
            throw ServiceError.httpStatus(response.statusCode)
        }
        do { return try JSONDecoder().decode(Response.self, from: data) }
        catch { throw ServiceError.decodingFailed(error) }
    }

    private static func catalogCover(_ id: Int) -> String {
        "https://covers.openlibrary.org/b/id/\(id)-M.jpg"
    }

    private struct OpenLibrarySearch: Decodable {
        let docs: [Document]
        let numFound: Int?
        let num_found: Int?
        struct Document: Decodable {
            let key: String
            let title: String?
            let author_name: [String]?
            let cover_i: Int?
            let subject: [String]?
        }
    }

    private struct OpenLibraryWork: Decodable {
        let title: String?
        let description: Description?
        let covers: [Int]?
        let subjects: [String]?
        struct Description: Decodable {
            let value: String
            private enum CodingKeys: String, CodingKey { case value }
            init(from decoder: Decoder) throws {
                if let text = try? decoder.singleValueContainer().decode(String.self) { value = text }
                else { value = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .value) }
            }
        }
    }

    static func secureImageURL(_ urlString: String?) -> String {
        guard var url = urlString, !url.isEmpty else { return "" }
        if url.hasPrefix("http://") { url = "https://" + url.dropFirst("http://".count) }
        return url
    }

    enum ServiceError: LocalizedError {
        case invalidQuery, queryTooShort, invalidURL, invalidResponse, noResults, notFound
        case httpStatus(Int)
        case decodingFailed(Error)

        var canUseFallback: Bool {
            if case .httpStatus(let status) = self {
                return [400, 401, 403, 429].contains(status) || (500...599).contains(status)
            }
            return false
        }

        var errorDescription: String? {
            switch self {
            case .invalidQuery: return "Enter a book title or author to search."
            case .queryTooShort: return "Enter at least \(BookCatalogService.minimumSearchQueryLength) characters to search."
            case .invalidURL, .invalidResponse, .decodingFailed:
                return "The book catalog returned an unexpected response. Please try again."
            case .noResults, .notFound: return "This book could not be found in the catalog."
            case .httpStatus(429): return "The book catalog is busy. Please wait a moment and try again."
            case .httpStatus(401), .httpStatus(403): return "The book catalog is unavailable. Please try again later."
            case .httpStatus: return "The book catalog could not complete your request. Please try again."
            }
        }
    }
}
