import Foundation
import SwiftData
import Testing
@testable import textual

@MainActor
struct UpNextQueueTests {
    @Test func queuePersistsMovesAndRemovesWithoutDeletingBooks() throws {
        let container = try ModelContainer(for: Book.self, Tag.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let a = Book(title: "A", author: "Author", isbn: "a")
        let b = Book(title: "B", author: "Author", isbn: "b")
        let c = Book(title: "C", author: "Author", isbn: "c")
        for book in [a,b,c] { context.insert(book) }
        try UpNextQueue.save([b,a,c], context: context, repository: nil)
        #expect(UpNextQueue.books(in: [a,b,c]).map(\.id) == [b.id,a.id,c.id])
        let moved = UpNextQueue.moving(c.id, to: b.id, in: [b,a,c])
        #expect(moved.map(\.id) == [c.id,b.id,a.id])
        #expect(UpNextQueue.moving(c.id, to: a.id, in: moved).map(\.id) == [b.id,a.id,c.id])
        try UpNextQueue.save(moved, context: context, repository: nil)
        let reopened = ModelContext(container)
        #expect(UpNextQueue.books(in: try reopened.fetch(FetchDescriptor<Book>())).map(\.id) == [c.id,b.id,a.id])
        try UpNextQueue.save([c,a], removing: b, context: context, repository: nil)
        #expect(UpNextQueue.books(in: [a,b,c]).map(\.id) == [c.id,a.id])
        #expect(!b.isRemovedFromLibrary)
        #expect(b.importedReading?.status == "to-read")
        try UpNextQueue.save([c,a,b], context: context, repository: nil)
        #expect(UpNextQueue.books(in: [a,b,c]).last?.id == b.id)
    }

    @Test func explicitImportedQueueTagsAreRecognizedButNotAllTBRBooks() throws {
        let tagged = try book("Tagged", status: "to-read", tags: ["up-next"])
        let reading = try book("Reading", status: "currently-reading", tags: ["up next"])
        let plain = try book("Plain", status: "to-read", tags: [])
        let removed = try book("Removed", status: "to-read", tags: ["Up Next"])
        removed.isRemovedFromLibrary = true
        #expect(UpNextQueue.books(in: [tagged,reading,plain,removed]).map(\.id) == [tagged.id])
        var metadata = try #require(tagged.importedReading)
        metadata.upNextExcluded = true
        tagged.storyGraphData = try JSONEncoder().encode(metadata)
        #expect(UpNextQueue.books(in: [tagged]).isEmpty)
        let catalog = ArchiveFilterCatalog(books: [tagged,reading,plain,removed])
        #expect(catalog.books(matching: .init(status: .all)).count == 3)
        #expect(catalog.books(matching: .init(status: .reading)).map(\.id) == [reading.id])
    }

    @Test func queueMetadataSurvivesCodingAndReimportWhileReadingDataUpdates() throws {
        let book = try book("Book", status: "to-read", tags: ["up-next"])
        var saved = try #require(book.importedReading)
        saved.upNextPosition = 3
        saved.upNextExcluded = false
        let roundtrip = try JSONDecoder().decode(StoryGraphReadingData.self, from: JSONEncoder().encode(saved))
        #expect(roundtrip == saved)
        let updated = try #require(try self.book("Book", status: "read", tags: ["new-tag"]).importedReading)
            .preservingQueue(from: roundtrip)
        #expect(updated.upNextPosition == 3)
        #expect(updated.upNextExcluded == false)
        #expect(updated.status == "read")
        #expect(updated.tags == ["new-tag"])
    }

    private func book(_ title: String, status: String, tags: [String]) throws -> Book {
        let book = Book(title: title, author: "Author", isbn: title)
        book.storyGraphData = try JSONEncoder().encode(StoryGraphReadingData(sourceKey: String(repeating: "a", count: 64),
            status: status, dateAdded: nil, lastDateRead: nil, periods: [], readCount: nil, rating: nil,
            format: "", moods: [], pace: "", tags: tags, owned: nil, originalFields: [:]))
        return book
    }
}
