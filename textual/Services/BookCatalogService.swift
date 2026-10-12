import Foundation

/// Shared catalog repository: typed search scopes, provider routing, bounded caches,
/// and cancellation-aware rate limiting. Views do not choose providers or build URLs.
actor BookCatalogService {
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
            URLQueryItem(name: "fields", value: "key,title,author_name,cover_i")
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
                averageRating: nil, ratingsCount: nil, categories: nil
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
    }

    /// Classification is work-level metadata. Prefer Google even when an existing
    /// book was resolved through Open Library; only accept a verified book match.
    func classification(isbn: String, title: String, author: String,
                        savedCategories: [String], savedSource: String) async throws -> ClassificationEvidence? {
        let normalizedISBN = StoryGraphImporter.normalizedISBN(isbn)
        if Date() >= googleRetryAfter {
            do {
                if let normalizedISBN {
                    do {
                        let page = try await googleClassificationSearch("isbn:\(normalizedISBN)")
                        if let evidence = Self.classificationEvidence(page, isbn: normalizedISBN, title: title, author: author, requireISBN: true) {
                            return evidence
                        }
                    } catch let error as ServiceError {
                        // An ISBN query can fail while a plain title search still works.
                        if case .httpStatus(let status) = error, (500...599).contains(status) {} else { throw error }
                    }
                }
                try Task.checkCancellation()
                if !Self.classificationTitle(title).isEmpty && !Self.matchKey(author).isEmpty {
                    let query = "\(Self.classificationTitle(title)) \(author)"
                    let page = try await googleClassificationSearch(query)
                    if let evidence = Self.classificationEvidence(page, isbn: normalizedISBN, title: title, author: author, requireISBN: false) {
                        return evidence
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                // Authentication and quota failures affect the project. A transient
                // per-query server error must not disable every other book lookup.
                if case ServiceError.httpStatus(let status) = error, [401, 403, 429].contains(status) {
                    googleRetryAfter = Date().addingTimeInterval(300)
                }
            }
        }
        try Task.checkCancellation()
        if !savedCategories.isEmpty {
            return ClassificationEvidence(categories: savedCategories, source: savedSource)
        }
        // Missing ISBNs and empty edition records still get a work lookup, verified
        // by both title and author. A first search result alone is never enough.
        guard !Self.classificationTitle(title).isEmpty, !Self.matchKey(author).isEmpty else { return nil }
        let query = "title:\"\(Self.classificationTitle(title))\" author:\"\(author.replacingOccurrences(of: "\"", with: ""))\""
        let page = try await searchPage(query: query, provider: .openLibrary)
        var evidence: [ClassificationEvidence] = []
        for candidate in page.items.filter({ Self.matchesWork($0, title: title, author: author) }).prefix(3) {
            guard let id = candidate.id else { continue }
            let item = try await fetchVolume(id: id)
            let categories = item.volumeInfo?.categories ?? []
            if !categories.isEmpty {
                evidence.append(ClassificationEvidence(categories: categories, source: "openlibrary"))
            }
        }
        guard let first = evidence.first, evidence.allSatisfy({
            BookFictionKind.classify($0.categories) == BookFictionKind.classify(first.categories)
        }) else { return nil }
        return first
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

    nonisolated static func matchesWork(_ item: BookItem, title: String, author: String) -> Bool {
        guard let info = item.volumeInfo, let candidateTitle = info.title else { return false }
        let expected = matchKey(classificationTitle(title))
        let authors = author.components(separatedBy: ",").map(matchKey).filter { !$0.isEmpty }
        let fullTitle = candidateTitle + (info.subtitle.map { ": " + $0 } ?? "")
        let titleMatches = [candidateTitle, fullTitle].contains { matchKey(classificationTitle($0)) == expected }
        return !expected.isEmpty && titleMatches
            && (info.authors ?? []).contains { authors.contains(matchKey($0)) }
    }

    nonisolated static func classificationEvidence(_ items: [BookItem], isbn: String?, title: String,
                                                   author: String, requireISBN: Bool) -> ClassificationEvidence? {
        let candidates = items.filter { item in
            if requireISBN {
                guard let isbn = isbn.flatMap(StoryGraphImporter.normalizedISBN) else { return false }
                return item.volumeInfo?.industryIdentifiers?.contains {
                    StoryGraphImporter.normalizedISBN($0.identifier ?? "") == isbn
                } == true
            }
            return matchesWork(item, title: title, author: author)
        }
        let categories = Array(Set(candidates.flatMap { $0.volumeInfo?.categories ?? [] })).sorted()
        guard !categories.isEmpty else { return nil }
        let kinds = Set(candidates.compactMap { BookFictionKind.classify($0.volumeInfo?.categories ?? []) })
        // Conflicting editions are not a reliable category source.
        guard kinds.count <= 1 else { return nil }
        let normalizedISBN = isbn.flatMap(StoryGraphImporter.normalizedISBN)
        let pages = normalizedISBN.flatMap { exactEditionPageCount(items: candidates, isbn: $0) }
        return ClassificationEvidence(categories: categories, source: "google", editionPages: pages,
                                      editionISBN: pages == nil ? nil : normalizedISBN)
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
        while true {
            try Task.checkCancellation()
            let delay = minimumRequestInterval - Date().timeIntervalSince(lastCatalogRequestStarted)
            if delay <= 0 {
                lastCatalogRequestStarted = Date()
                return
            }
            // A canceled waiter never reserves time. Recheck after actor reentry.
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func request<Response: Decodable>(_ url: URL, catalog: Bool = false,
                                               forceRefresh: Bool = false) async throws -> Response {
        if catalog { try await acquireCatalogSlot() }
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
