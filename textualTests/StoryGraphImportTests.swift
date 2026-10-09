import Foundation
import SwiftData
import Testing
@testable import textual

struct StoryGraphImportTests {
    static func csv(_ rows: [[String]]) -> Data {
        let headers = ["Title", "Authors", "ISBN/UID", "Read Status", "Date Added", "Dates Read", "Read Count", "Star Rating", "Review"]
        return Data(([headers] + rows).map { $0.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",") }.joined(separator: "\r\n").utf8)
    }
    static let row = ["A, book", "Author", "9780140328721", "read", "2024/01/02", "2024/02/01-2024/02/14, 2025/01/01-2025/01/10", "3", "4.75", "A \"quoted\" review\nwith another line."]

    @Test func quotedCSVPreservesHistoryAndOriginalFields() throws {
        let data = Data([0xEF,0xBB,0xBF]) + Self.csv([Self.row])
        let document = try StoryGraphImporter.parse(data)
        let record = try #require(document.records.first)
        #expect(record.title == "A, book")
        #expect(record.reading.rating == 4.75)
        #expect(record.reading.readCount == 3)
        #expect(record.reading.periods.count == 2)
        #expect(record.reading.periods[0].finishedOn == "2024-02-14")
        #expect(record.reading.originalFields["Review"] == Self.row[8])
        #expect(try JSONDecoder().decode(StoryGraphReadingData.self, from: JSONEncoder().encode(record.reading)) == record.reading)
    }
    @Test func repeatsAreIdempotentButConflictingRowsReject() throws {
        #expect(try StoryGraphImporter.parse(Self.csv([Self.row, Self.row])).duplicateRows == 1)
        var changed = Self.row; changed[7] = "2"
        #expect(throws: (any Error).self) { try StoryGraphImporter.parse(Self.csv([Self.row, changed])) }
    }
    @Test func missingIdentifiersAndDatesDoNotInventHistory() throws {
        var row = Self.row; row[2] = ""; row[5] = ""; row[6] = ""; row[7] = ""
        let record = try #require(StoryGraphImporter.parse(Self.csv([row])).records.first)
        #expect(record.isbn == nil)
        #expect(record.reading.periods.isEmpty)
        #expect(record.reading.readCount == nil)
        #expect(record.reading.rating == nil)
        #expect(record.reading.sourceKey.count == 64)
        #expect(StoryGraphImporter.normalizedISBN("0-14-032872-6") == "9780140328721")
        #expect(StoryGraphImporter.normalizedDate("2024/02/30") == nil)
    }
    @Test func malformedAndOversizedFilesReject() {
        #expect(throws: (any Error).self) { try StoryGraphImporter.parse(Data("Title,Authors\n\"unfinished".utf8)) }
        #expect(throws: (any Error).self) { try StoryGraphImporter.parse(Data(repeating: 65, count: StoryGraphImporter.maximumFileBytes + 1)) }
        var row = Self.row; row[7] = "nan"
        #expect(throws: (any Error).self) { try StoryGraphImporter.parse(Self.csv([row])) }
    }

    @Test @MainActor func importIsPrivateDurableAndRepeatable() async throws {
        let schema = Schema([Book.self, Tag.self, LibrarySyncState.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let user = UUID()
        let transport = ImportTestTransport(user: user)
        let repository = LibraryRepository(userID: user, modelContext: container.mainContext, transport: transport)
        let document = try StoryGraphImporter.parse(Self.csv([Self.row]))
        #expect(try repository.previewStoryGraphImport(document).added == 1)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Book>()) == 0)
        #expect(try await repository.importStoryGraph(document, expectedUserID: user).added == 1)
        let book = try #require(container.mainContext.fetch(FetchDescriptor<Book>()).first)
        let operation = book.pendingOperationID
        let payload = try JSONDecoder().decode(LibraryChange.self, from: #require(book.pendingOperationData))
        #expect(payload.readingData == document.records[0].reading)
        #expect(payload.book.provider == "storygraph")
        #expect(try await repository.importStoryGraph(document, expectedUserID: user).unchanged == 1)
        #expect(book.pendingOperationID == operation)
        var changed = Self.row; changed[7] = "3.5"
        #expect(try await repository.importStoryGraph(StoryGraphImporter.parse(Self.csv([changed])), expectedUserID: user).updated == 1)
        #expect(book.importedReading?.rating == 3.5)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Book>()) == 1)
        do {
            _ = try await repository.importStoryGraph(document, expectedUserID: UUID())
            Issue.record("An account mismatch must reject import")
        } catch { }
        #expect(book.importedReading?.rating == 3.5)
        repository.stop()
        #expect(throws: (any Error).self) { try repository.previewStoryGraphImport(document) }
    }
}

private actor ImportTestTransport: LibrarySyncTransport {
    let user: UUID
    init(user: UUID) { self.user = user }
    func authenticatedUserID() async throws -> UUID { user }
    func synchronize(_ request: LibrarySyncRequest) async throws -> LibrarySyncResponse { throw URLError(.notConnectedToInternet) }
}
