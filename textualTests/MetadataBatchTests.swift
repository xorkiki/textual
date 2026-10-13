import Foundation
import SwiftData
import Testing
@testable import textual

@MainActor @Suite(.serialized)
struct MetadataBatchTests {
    @Test func warmupBatchesVisibleChangesAndKeepsAnEditMadeDuringLookup() async throws {
        let schema = Schema([Book.self, Tag.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let books = (0..<5).map { index -> Book in
            let book = Book(title: "Book \(index)", author: "Writer", isbn: "9780140328721", googleBooksVolumeId: "volume\(index)")
            book.cachedCatalogMetadata = Data(#"{"id":"volume","volumeInfo":{"categories":["Fiction / Fantasy"],"pageCount":240}}"#.utf8)
            container.mainContext.insert(book)
            return book
        }
        try container.mainContext.save()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); MetadataProtocol.setCallback(nil) }
        var calls = 0
        var sawBatching = false
        MetadataProtocol.setCallback {
            calls += 1
            if calls == 2 {
                sawBatching = books[0].cachedStatsClassification == nil
                books[0].title = "Edited during lookup"
            }
        }
        let service = BookCatalogService(session: session, apiKey: "fixture", minimumRequestInterval: 0)
        await StatsMetadataCache.warm(books, service: service)
        #expect(sawBatching)
        #expect(books[0].title == "Edited during lookup" && books[0].cachedStatsClassification == nil)
        #expect(books.dropFirst().allSatisfy { $0.statsClassificationVersion == StatsMetadataCache.classificationVersion && $0.cachedStatsClassification != nil })
        let saved = try ModelContext(container).fetch(FetchDescriptor<Book>())
        #expect(saved.filter { $0.cachedStatsClassification != nil }.count == 4)
    }
}

private final class MetadataProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var callback: (@MainActor @Sendable () -> Void)?
    static func setCallback(_ value: (@MainActor @Sendable () -> Void)?) { lock.withLock { callback = value } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let callback = Self.lock.withLock { Self.callback }
        Task {
            await callback?()
            guard let url = request.url else { return }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"items":[{"id":"volume","volumeInfo":{"categories":["Fiction / Fantasy"],"industryIdentifiers":[{"identifier":"9780140328721"}],"pageCount":240}}]}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
