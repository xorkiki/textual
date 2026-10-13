import Foundation
import Testing
@testable import textual

@Suite(.serialized)
struct CatalogPriorityTests {
    @Test func interactiveSearchOvertakesQueuedMetadataWork() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PriorityProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        PriorityProtocol.reset()
        let service = BookCatalogService(session: session, apiKey: nil, minimumRequestInterval: 0.5)
        _ = try await service.searchPage(query: "prime")
        let background = Task {
            try await BookCatalogService.$isBackgroundLookup.withValue(true) {
                try await service.searchPage(query: "background")
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        _ = try await service.searchPage(query: "interactive")
        _ = try await background.value
        #expect(PriorityProtocol.queries == ["prime", "interactive", "background"])
    }

    @Test func cancellingAnInteractiveWaiterDoesNotBlockBackgroundWork() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PriorityProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        PriorityProtocol.reset()
        let service = BookCatalogService(session: session, apiKey: nil, minimumRequestInterval: 0.2)
        _ = try await service.searchPage(query: "prime")
        let foreground = Task { try await service.searchPage(query: "cancelled") }
        try await Task.sleep(for: .milliseconds(30))
        foreground.cancel()
        _ = try? await foreground.value
        _ = try await BookCatalogService.$isBackgroundLookup.withValue(true) {
            try await service.searchPage(query: "background")
        }
        #expect(PriorityProtocol.queries == ["prime", "background"])
    }
}

private final class PriorityProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var recorded: [String] = []
    static var queries: [String] { lock.withLock { recorded } }
    static func reset() { lock.withLock { recorded = [] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
        Self.lock.withLock { Self.recorded.append(query) }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"numFound":0,"docs":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
