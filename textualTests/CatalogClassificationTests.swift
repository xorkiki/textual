import Foundation
import SwiftData
import Testing
@testable import textual

@Suite(.serialized)
struct CatalogClassificationTests {
    private let isbn = "9780140328721"

    @Test func pageEstimatesOnlyUseLinkedEditionsAndCacheTheirLengths() async throws {
        let (service, session) = makeService { request in
            switch request.url!.path {
            case "/isbn/9780140328721.json": return (200, #"{"isbn_13":["9780140328721"],"works":[{"key":"/works/OL123W"}]}"#)
            case "/works/OL123W/editions.json":
                return (200, #"{"entries":[{"works":[{"key":"/works/OL123W"}],"number_of_pages":280},{"works":[{"key":"/works/OL123W"}],"number_of_pages":320},{"works":[{"key":"/works/OL999W"}],"number_of_pages":999},{"number_of_pages":888},{"works":[{"key":"/works/OL123W"}],"number_of_pages":0}]}"#)
            default: throw URLError(.badURL)
            }
        }
        defer { session.invalidateAndCancel() }
        let counts = try await service.estimatedPageCounts(isbn: isbn, title: "Translated Title", author: "Writer")
        #expect(counts == [280, 320])
        #expect(try await service.estimatedPageCounts(isbn: isbn, title: "Translated Title", author: "Writer") == counts)
        #expect(ClassificationProtocol.requests.filter { $0.url?.path.hasSuffix("editions.json") == true }.count == 1)
    }

    @Test func pageEstimatesRejectWrongAuthorAndUseTitleVerifiedWork() async throws {
        let (service, session) = makeService { request in
            switch request.url!.path {
            case "/books/v1/volumes": return (200, #"{"items":[{"id":"wrong","volumeInfo":{"title":"Sparse Book","authors":["Someone Else"],"pageCount":999}}]}"#)
            case "/search.json": return (200, #"{"docs":[{"key":"/works/OL123W","title":"Sparse Book","author_name":["Writer"]}]}"#)
            case "/works/OL123W/editions.json": return (200, #"{"entries":[{"works":[{"key":"/works/OL123W"}],"number_of_pages":340}]}"#)
            default: throw URLError(.badURL)
            }
        }
        defer { session.invalidateAndCancel() }
        #expect(try await service.estimatedPageCounts(isbn: "", title: "Sparse Book", author: "Writer") == [340])
    }


    @Test func contextOnlyEvidenceRequiresVerifiedIdentityAndSurvivesMerging() throws {
        func item(_ author: String) throws -> BookCatalogService.BookItem {
            let data = try JSONSerialization.data(withJSONObject: ["id": "fixture", "volumeInfo": [
                "title": "Unfamiliar Book", "authors": [author], "subtitle": "A novel",
                "description": "An adventurous fantasy."]])
            return try JSONDecoder().decode(BookCatalogService.BookItem.self, from: data)
        }
        #expect(BookCatalogService.classificationEvidence([try item("Other Author")], isbn: nil,
            title: "Unfamiliar Book", author: "Writer", requireISBN: false) == nil)
        let evidence = try #require(BookCatalogService.classificationEvidence([try item("Writer")], isbn: nil,
            title: "Unfamiliar Book", author: "Writer", requireISBN: false))
        #expect(evidence.categories.isEmpty && !evidence.isComplete)
        #expect(evidence.context?.contains("A novel") == true)
        let merged = evidence.supplemented(with: .init(categories: ["Fantasy"], source: "openlibrary", context: ["Another synopsis"]))
        #expect(merged.context?.contains("A novel") == true && merged.context?.contains("Another synopsis") == true)
        let decoded = try JSONDecoder().decode(BookCatalogService.ClassificationEvidence.self, from: JSONEncoder().encode(merged))
        #expect(decoded.context == merged.context)
        let legacy = try JSONDecoder().decode(BookCatalogService.ClassificationEvidence.self,
            from: Data(#"{"categories":["Fiction"],"source":"google"}"#.utf8))
        #expect(legacy.context == nil)
    }


    @Test func searchSummaryIsEnrichedFromVerifiedVolumeDetail() async throws {
        let (service, session) = makeService { request in
            switch request.url!.path {
            case "/books/v1/volumes":
                return (200, #"{"items":[{"id":"fixture","volumeInfo":{"title":"An Invented Book","authors":["A. Writer"],"categories":["Fiction"],"industryIdentifiers":[{"identifier":"9780140328721"}]}}]}"#)
            case "/books/v1/volumes/fixture":
                return (200, #"{"id":"fixture","volumeInfo":{"title":"An Invented Book","mainCategory":"Fiction / Mystery / Detective"}}"#)
            default: throw URLError(.badURL)
            }
        }
        defer { session.invalidateAndCancel() }
        let result = try await service.classificationLookup(isbn: isbn, title: "An Invented Book", author: "A. Writer", savedCategories: [], savedSource: "google")
        #expect(result.evidence?.genres == ["Mystery"])
        #expect(result.evidence?.fictionKind == .fiction)
        #expect(result.usedGoogleKey && !result.retryRequired)
        #expect(ClassificationProtocol.requests.count == 2)
    }

    @Test func audienceOnlySearchResultStillLoadsGenreFromDetails() async throws {
        let (service, session) = makeService { request in
            if request.url!.path == "/books/v1/volumes" {
                return (200, #"{"items":[{"id":"fixture","volumeInfo":{"title":"Invented Novel","authors":["A Writer"],"categories":["Young Adult Fiction"]}}]}"#)
            }
            return (200, #"{"id":"fixture","volumeInfo":{"categories":["Young Adult Fiction / Science Fiction"]}}"#)
        }
        defer { session.invalidateAndCancel() }
        let result = try await service.classification(isbn: "", title: "Invented Novel", author: "A Writer", savedCategories: [], savedSource: "google")
        #expect(result?.genres == ["Young adult", "Science fiction"])
        #expect(ClassificationProtocol.requests.count == 2)
    }

    @Test func exactISBNFindsWorkDespiteDifferentEditionTitleAndCredits() async throws {
        let (service, session) = makeService { request in
            switch request.url!.path {
            case "/books/v1/volumes": return (200, #"{"items":[]}"#)
            case "/isbn/9780140328721.json":
                return (200, #"{"isbn_10":["0140328726"],"title":"Translated Edition","works":[{"key":"/works/OL123W"}],"number_of_pages":240}"#)
            case "/works/OL123W.json":
                return (200, #"{"title":"Original Title","subjects":["Fiction / Fantasy"]}"#)
            default: throw URLError(.badURL)
            }
        }
        defer { session.invalidateAndCancel() }
        let result = try await service.classification(isbn: isbn, title: "Translated Edition: An Unabridged Reading", author: "Writer, Narrator", savedCategories: [], savedSource: "google")
        #expect(result?.genres == ["Fantasy"])
        #expect(result?.editionPages == 240 && result?.editionISBN == isbn)
        #expect(!ClassificationProtocol.requests.contains { $0.url?.path == "/search.json" })
    }

    @Test func editionSubjectsAreUsedEvenWhenWorkHasNoSubjects() async throws {
        let (service, session) = makeService { request in
            switch request.url!.path {
            case "/books/v1/volumes": return (200, #"{"items":[]}"#)
            case "/isbn/9780140328721.json":
                return (200, #"{"isbn_13":["9780140328721"],"subjects":["Biography & Autobiography / Memoir"],"works":[{"key":"/works/OL124W"}]}"#)
            default: return (200, #"{"title":"A Memoir"}"#)
            }
        }
        defer { session.invalidateAndCancel() }
        let result = try await service.classification(isbn: isbn, title: "A Memoir", author: "Some Writer", savedCategories: [], savedSource: "google")
        #expect(result?.fictionKind == .nonfiction)
        #expect(result?.genres.contains("Memoir") == true)
    }

    @Test func searchSubjectsSurviveAWorkEndpointFailure() async throws {
        let (service, session) = makeService { request in
            switch request.url!.path {
            case "/books/v1/volumes": return (200, #"{"items":[]}"#)
            case "/search.json":
                let fields = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "fields" }?.value ?? ""
                #expect(fields.components(separatedBy: ",").contains("subject"))
                return (200, #"{"docs":[{"key":"/works/OL125W","title":"An Invented Book","author_name":["A. B. Writer"],"subject":["Fiction / Romance"]}]}"#)
            default: return (503, "{}")
            }
        }
        defer { session.invalidateAndCancel() }
        let result = try await service.classification(isbn: "", title: "An Invented Book", author: "AB Writer", savedCategories: [], savedSource: "google")
        #expect(result?.genres == ["Romance"])
    }

    @Test func wrongISBNAndWrongAuthorNeverSupplyClassification() async throws {
        let (service, session) = makeService { request in
            switch request.url!.path {
            case "/books/v1/volumes":
                return (200, #"{"items":[{"id":"wrong","volumeInfo":{"title":"Same Title","authors":["Other Writer"],"categories":["Fiction / Horror"]}}]}"#)
            case "/isbn/9780140328721.json":
                return (200, #"{"isbn_13":["9780439708180"],"subjects":["Fiction / Horror"],"works":[{"key":"/works/OL999W"}]}"#)
            case "/search.json":
                return (200, #"{"docs":[{"key":"/works/OL999W","title":"Same Title","author_name":["Other Writer"],"subject":["Fiction / Horror"]}]}"#)
            default: Issue.record("An unrelated detail record was fetched"); return (404, "{}")
            }
        }
        defer { session.invalidateAndCancel() }
        let result = try await service.classificationLookup(isbn: isbn, title: "Same Title", author: "Correct Writer", savedCategories: [], savedSource: "google")
        #expect(result.evidence == nil)
        #expect(!result.retryRequired)
    }

    @Test func failedLookupIsDistinguishedFromSuccessfulEmptyResult() async throws {
        let (service, session) = makeService { _ in (503, "{}") }
        defer { session.invalidateAndCancel() }
        let result = try await service.classificationLookup(isbn: "", title: "Invented Title", author: "A Writer", savedCategories: [], savedSource: "google")
        #expect(result.evidence == nil)
        #expect(result.retryRequired && !result.usedGoogleKey)
    }

    @Test func quotaFallbackDoesNotPretendGoogleWasSuccessfullyChecked() async throws {
        let (service, session) = makeService { _ in (429, "{}") }
        defer { session.invalidateAndCancel() }
        for _ in 0..<2 {
            let result = try await service.classificationLookup(isbn: "", title: "Invented Title", author: "A Writer", savedCategories: ["Fiction / Fantasy"], savedSource: "openlibrary")
            #expect(result.evidence?.genres == ["Fantasy"])
            #expect(!result.usedGoogleKey)
        }
        #expect(ClassificationProtocol.requests.count == 1)
    }

    @Test @MainActor func warmupPreservesEvidenceAndRetriesOutagesWithoutDailyLockout() async throws {
        let schema = Schema([Book.self, Tag.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let book = Book(title: "Invented Title", author: "A Writer", isbn: "")
        book.cachedCatalogMetadata = Data(#"{"id":"old","volumeInfo":{"categories":["Fiction"],"pageCount":100}}"#.utf8)
        book.cachedStatsClassification = try JSONEncoder().encode(BookCatalogService.ClassificationEvidence(categories: ["Fiction / Mystery"], source: "google"))
        book.statsClassificationVersion = 2
        book.statsClassificationCheckedAt = Date()
        book.statsClassificationUsedGoogleKey = true
        container.mainContext.insert(book)
        try container.mainContext.save()
        let (service, session) = makeService { _ in (503, "{}") }
        defer { session.invalidateAndCancel() }
        await StatsMetadataCache.warm([book], service: service)
        #expect(StatsMetadataCache.genres(book) == ["Mystery"])
        #expect(book.statsClassificationCheckedAt == nil)
        #expect(StatsMetadataCache.needsClassification(book, googleConfigured: true))
        #expect(book.statsClassificationVersion == StatsMetadataCache.classificationVersion)
    }

    @Test @MainActor func upgradedCacheRefreshesOnceForAnyBookThenPersists() async throws {
        let schema = Schema([Book.self, Tag.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let book = Book(title: "Synthetic Title", author: "Writer", isbn: "9780140328721")
        book.cachedStatsClassification = try JSONEncoder().encode(BookCatalogService.ClassificationEvidence(categories: ["Fiction"], source: "google"))
        book.statsClassificationVersion = 2
        book.statsClassificationCheckedAt = Date()
        book.statsClassificationUsedGoogleKey = true
        container.mainContext.insert(book)
        try container.mainContext.save()
        let (service, session) = makeService { _ in
            (200, #"{"items":[{"volumeInfo":{"categories":["Fiction / Mystery"],"industryIdentifiers":[{"identifier":"9780140328721"}],"pageCount":240}}]}"#)
        }
        defer { session.invalidateAndCancel() }
        await StatsMetadataCache.warm([book], service: service)
        #expect(StatsMetadataCache.genres(book) == ["Mystery"])
        #expect(ReadingBookSnapshot(ReadingBookInput(book)).genres == ["Mystery"])
        #expect(!StatsMetadataCache.needsClassification(book, googleConfigured: true))
        let count = ClassificationProtocol.requests.count
        await StatsMetadataCache.warm([book], service: service)
        #expect(ClassificationProtocol.requests.count == count)
        let saved = try ModelContext(container).fetch(FetchDescriptor<Book>())
        #expect(saved.count == 1 && StatsMetadataCache.genres(saved[0]) == ["Mystery"])
    }

    @Test func conflictingSearchCandidatesAreNotResolvedByPickingTheFirstDetail() async throws {
        let (service, session) = makeService { request in
            if request.url?.host == "www.googleapis.com" {
                #expect(request.url?.path == "/books/v1/volumes")
                return (200, #"{"items":[{"id":"first","volumeInfo":{"title":"Invented Title","authors":["A Writer"],"categories":["Fiction"]}},{"id":"second","volumeInfo":{"title":"Invented Title","authors":["A Writer"],"categories":["Nonfiction"]}}]}"#)
            }
            return (200, #"{"docs":[]}"#)
        }
        defer { session.invalidateAndCancel() }
        let result = try await service.classification(isbn: "", title: "Invented Title", author: "A Writer", savedCategories: [], savedSource: "google")
        #expect(result == nil)
    }

    @Test func contradictoryVolumeDetailIsRejected() async throws {
        let (service, session) = makeService { request in
            if request.url?.path == "/books/v1/volumes" {
                return (200, #"{"items":[{"id":"expected","volumeInfo":{"title":"Invented Title","authors":["A Writer"],"categories":["Fiction"]}}]}"#)
            }
            if request.url?.path == "/books/v1/volumes/expected" {
                return (200, #"{"id":"different","volumeInfo":{"title":"Other Title","categories":["Fiction / Horror"]}}"#)
            }
            return (200, #"{"docs":[]}"#)
        }
        defer { session.invalidateAndCancel() }
        let result = try await service.classification(isbn: "", title: "Invented Title", author: "A Writer", savedCategories: [], savedSource: "google")
        #expect(result?.genres.isEmpty == true)
    }

    @Test func detailRequestsAreBoundedEvenWhenEveryEditionIsSparse() async throws {
        let (service, session) = makeService { request in
            switch request.url!.path {
            case "/books/v1/volumes":
                let items = (1...10).map { ["id": "candidate-\($0)", "volumeInfo": ["title":"Invented Title", "authors":["A Writer"], "categories":["Fiction"]]] as [String:Any] }
                let data = try JSONSerialization.data(withJSONObject: ["items": items])
                return (200, String(decoding: data, as: UTF8.self))
            case "/search.json": return (200, #"{"docs":[]}"#)
            default: return (200, #"{"volumeInfo":{"categories":["Fiction"]}}"#)
            }
        }
        defer { session.invalidateAndCancel() }
        _ = try await service.classification(isbn: "", title: "Invented Title", author: "A Writer", savedCategories: [], savedSource: "google")
        #expect(ClassificationProtocol.requests.filter { $0.url!.path.hasPrefix("/books/v1/volumes/") }.count == 3)
    }

    @Test func cancelledLookupCannotBecomeASuccessfulNegativeCacheEntry() async throws {
        let (service, session) = makeService { _ in
            Issue.record("A cancelled lookup must not issue requests")
            return (200, "{}")
        }
        defer { session.invalidateAndCancel() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.classificationLookup(isbn: "", title: "Invented Title", author: "A Writer", savedCategories: [], savedSource: "google")
        }
        do {
            _ = try await task.value
            Issue.record("Cancellation must propagate")
        } catch is CancellationError { }
    }

    @Test func sparseWorkUsesSubjectsFromOtherVerifiedEditions() async throws {
        let (service, session) = makeService { request in
            switch request.url!.path {
            case "/books/v1/volumes": return (503, "{}")
            case "/isbn/9780140328721.json":
                return (200, #"{"isbn_13":["9780140328721"],"works":[{"key":"/works/OL126W"}]}"#)
            case "/works/OL126W.json": return (200, #"{"title":"Invented Novel"}"#)
            case "/works/OL126W/editions.json":
                #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "limit" }?.value == "20")
                return (200, #"{"entries":[{"works":[{"key":"/works/OL126W"}],"subjects":["Fiction, fantasy, epic","Fiction, romance, fantasy"],"number_of_pages":999}]}"#)
            default: Issue.record("Unexpected fallback request"); return (404, "{}")
            }
        }
        defer { session.invalidateAndCancel() }
        let result = try await service.classificationLookup(isbn: isbn, title: "Invented Novel", author: "A Writer", savedCategories: [], savedSource: "google")
        #expect(result.evidence?.fictionKind == .fiction)
        #expect(result.evidence?.genres == ["Fantasy", "Romance"])
        #expect(result.evidence?.editionPages == nil)
        #expect(!result.retryRequired)
    }

    @Test func titleVerifiedWorkCanUseEditionSubjectsWithoutAnISBN() async throws {
        let (service, session) = makeService { request in
            switch request.url!.path {
            case "/books/v1/volumes": return (200, #"{"items":[]}"#)
            case "/search.json":
                return (200, #"{"docs":[{"key":"/works/OL127W","title":"Invented Memoir","author_name":["A Writer"]}]}"#)
            case "/works/OL127W.json": return (200, #"{"title":"Invented Memoir"}"#)
            default:
                return (200, #"{"entries":[{"works":[{"key":"/works/OL127W"}],"subjects":["Women, biography"]}]}"#)
            }
        }
        defer { session.invalidateAndCancel() }
        let result = try await service.classification(isbn: "", title: "Invented Memoir", author: "A Writer", savedCategories: [], savedSource: "google")
        #expect(result?.fictionKind == .nonfiction)
        #expect(result?.genres == ["Biography"])
    }

    @Test func siblingEditionLookupRejectsUnlinkedAndConflictingRecords() async throws {
        for conflict in [false, true] {
            let (service, session) = makeService { request in
                switch request.url!.path {
                case "/books/v1/volumes": return (200, #"{"items":[]}"#)
                case "/isbn/9780140328721.json":
                    return (200, #"{"isbn_13":["9780140328721"],"works":[{"key":"/works/OL128W"}]}"#)
                case "/works/OL128W.json": return (200, #"{"title":"Invented Title"}"#)
                case "/works/OL128W/editions.json":
                    return conflict
                        ? (200, #"{"entries":[{"works":[{"key":"/works/OL128W"}],"subjects":["Fiction / Fantasy"]},{"works":[{"key":"/works/OL128W"}],"subjects":["Nonfiction / History"]}]}"#)
                        : (200, #"{"entries":[{"works":[{"key":"/works/OL999W"}],"subjects":["Fiction / Fantasy"]},{"subjects":["Fiction / Fantasy"]}]}"#)
                default: return (200, #"{"docs":[]}"#)
                }
            }
            let result = try await service.classification(isbn: isbn, title: "Invented Title", author: "A Writer", savedCategories: [], savedSource: "google")
            #expect(result == nil)
            session.invalidateAndCancel()
        }
    }

    @Test func siblingSubjectsAreCachedAndExactEditionPagesArePreserved() async throws {
        let (service, session) = makeService { request in
            switch request.url!.path {
            case "/books/v1/volumes": return (200, #"{"items":[]}"#)
            case "/isbn/9780140328721.json":
                return (200, #"{"isbn_13":["9780140328721"],"works":[{"key":"/works/OL129W"}],"number_of_pages":240}"#)
            case "/works/OL129W.json": return (200, #"{"title":"Invented Novel"}"#)
            default: return (200, #"{"entries":[{"works":[{"key":"/works/OL129W"}],"subjects":["Fiction / Fantasy"],"number_of_pages":999}]}"#)
            }
        }
        defer { session.invalidateAndCancel() }
        for _ in 0..<2 {
            let result = try await service.classification(isbn: isbn, title: "Invented Novel", author: "A Writer", savedCategories: [], savedSource: "google")
            #expect(result?.editionPages == 240)
            #expect(result?.genres == ["Fantasy"])
        }
        #expect(ClassificationProtocol.requests.filter { $0.url?.path.hasSuffix("/editions.json") == true }.count == 1)
    }

    @Test @MainActor func missingReadClassificationsAreProcessedBeforeKnownBooks() throws {
        func book(_ title: String, read: Bool, classified: Bool) throws -> Book {
            let book = Book(title: title, author: "Writer", isbn: "")
            book.storyGraphData = try JSONEncoder().encode(StoryGraphReadingData(sourceKey: title, status: read ? "read" : "to-read",
                dateAdded: nil, lastDateRead: nil, periods: [], readCount: read ? 1 : 0, rating: nil, format: "",
                moods: [], pace: "", tags: [], owned: nil, originalFields: [:]))
            if classified {
                book.cachedStatsClassification = try JSONEncoder().encode(BookCatalogService.ClassificationEvidence(categories: ["Fiction / Fantasy"], source: "google"))
            }
            return book
        }
        let knownRead = try book("A", read: true, classified: true)
        let unknownUnread = try book("B", read: false, classified: false)
        let unknownRead = try book("Z", read: true, classified: false)
        #expect(StatsMetadataCache.prioritizedForWarmup([knownRead, unknownUnread, unknownRead]).map(\.id)
            == [unknownRead.id, knownRead.id, unknownUnread.id])
    }

    private func makeService(_ handler: @escaping (URLRequest) throws -> (Int, String)) -> (BookCatalogService, URLSession) {
        ClassificationProtocol.configure(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClassificationProtocol.self]
        let session = URLSession(configuration: configuration)
        return (BookCatalogService(session: session, apiKey: "synthetic-test-key", minimumRequestInterval: 0), session)
    }
}

private final class ClassificationProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> (Int, String))?
    private static var recorded: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func configure(_ value: @escaping (URLRequest) throws -> (Int, String)) {
        lock.withLock { handler = value; recorded = [] }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.lock.withLock { Self.recorded.append(request); return Self.handler }
        do {
            guard let handler, let url = request.url else { throw URLError(.badURL) }
            let (status, json) = try handler(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
