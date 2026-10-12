import Foundation
import SwiftData
import Testing
@testable import textual

@MainActor
struct ReaderProfileTests {
    @Test func completedHistoryDrivesStatsWithoutCountingWishlistOrRemovedBooks() throws {
        let csv = """
        Title,Authors,ISBN/UID,Read Status,Date Added,Dates Read,Read Count,Moods,Pace
        First,Author,one,read,2024/01/01,,3,emotional,medium
        Second,Author,two,to-read,2024/01/01,,0,tense,fast
        Third,Author,three,read,2024/01/01,,1,funny,slow
        """
        let books = try StoryGraphImporter.parse(Data(csv.utf8)).records.map { record in
            let book = Book(title: record.title, author: record.author, isbn: record.reading.sourceKey)
            book.storyGraphData = try JSONEncoder().encode(record.reading)
            return book
        }
        books[2].isRemovedFromLibrary = true
        let content = ReaderPersonality.summarize(ReaderPersonality.evidence(books), favorites: [])
        #expect(content.stats.reads == 3)
        #expect(content.stats.rereads == 2)
        #expect(content.sentence.contains("judgment pending"))
    }

    @Test func personalityUsesCombinationsAndIsStableAcrossOrder() {
        let evidence = (0..<4).map { _ in ReaderPersonality.Evidence(completedReads: 1,
            genres: ["Fantasy", "Romance"], moods: ["Tense"], pace: "fast") }
        let line = ReaderPersonality.sentence(evidence)
        #expect(line.contains("under the covers"))
        #expect(line == ReaderPersonality.sentence(evidence.reversed()))
        #expect(ReaderPersonality.sentence([]).contains("judgment pending"))
        let single = [ReaderPersonality.Evidence(completedReads: 50, genres: ["Fantasy"], moods: [], pace: "")]
        #expect(ReaderPersonality.sentence(single).contains("judgment pending"))
        let unknown = (0..<5).map { _ in ReaderPersonality.Evidence(completedReads: 1, genres: [], moods: [], pace: "") }
        #expect(ReaderPersonality.sentence(unknown).contains("still getting a feel"))
    }

    @Test func shelfCapsDeduplicatesAndReordersWithoutLosingBooks() {
        let books = (0..<16).map { Book(title: "Book \($0)", author: "Author", isbn: "isbn-\($0)") }
        let full = books.reduce([ReaderFavorite]()) { ReaderShelf.adding($1, to: $0) }
        #expect(full.count == 15)
        #expect(ReaderShelf.adding(books[0], to: Array(full.prefix(3))).count == 3)
        let moved = ReaderShelf.moving(full[0].id, to: full[14].id, in: full)
        #expect(moved.last?.id == full[0].id)
        #expect(Set(moved.map(\.id)) == Set(full.map(\.id)))
        #expect(ReaderShelf.moving(UUID(), to: full[0].id, in: full) == full)
    }

    @Test func publicProjectionNeverIncludesImportNotes() throws {
        let book = Book(title: "A book", author: "An author", isbn: "123")
        book.storyGraphData = Data("private notes".utf8)
        let favorite = ReaderFavorite(book: book)
        let content = ReaderPersonality.summarize([], favorites: [favorite])
        let json = String(decoding: try JSONEncoder().encode(content), as: UTF8.self)
        #expect(!json.contains("private notes"))
        #expect(!json.contains("storyGraph"))
        #expect(favorite.detailBook().importedReading == nil)
        #expect(ReaderProfileRoute.username(URL(string: "textual://reader/reader_1")!) == "reader_1")
        #expect(ReaderProfileRoute.username(URL(string: "textual://auth/callback")!) == nil)
    }

    @Test func draftsAreDurableAndIsolatedByOwner() throws {
        let schema = Schema([ReaderProfileDraft.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let first = UUID(), second = UUID()
        let transport = ProfileFixtureTransport()
        let store = ReaderProfileStore(userID: first, context: container.mainContext, transport: transport)
        let other = ReaderProfileStore(userID: second, context: container.mainContext, transport: transport)
        let content = ReaderPersonality.summarize([], favorites: [])
        try store.update(content)
        #expect(try store.draft()?.content == content)
        #expect(try other.draft() == nil)
        #expect(try store.draft()?.needsUpload == true)
    }

    @Test func freshDeviceRestoresTheRemoteShelfAndConflictsRequireAChoice() async throws {
        let schema = Schema([ReaderProfileDraft.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let transport = ProfileFixtureTransport()
        let id = UUID()
        let favorite = ReaderFavorite(book: Book(title: "Keeper", author: "Author", isbn: "remote"))
        let remote = ReaderPersonality.summarize([], favorites: [favorite])
        _ = try await transport.publish(userID: id, revision: 4, content: remote)
        let store = ReaderProfileStore(userID: id, context: container.mainContext, transport: transport)
        try store.update(ReaderPersonality.summarize([], favorites: []))
        await store.synchronize(username: "reader")
        #expect(try store.draft()?.content?.favorites == [favorite])
        #expect(try store.draft()?.serverRevision == 5)
        // A concurrent remote update must not be overwritten by a pending local edit.
        try store.update(ReaderPersonality.summarize([], favorites: []))
        _ = try await transport.publish(userID: id, revision: 5, content: remote)
        await store.synchronize(username: "reader")
        #expect(store.conflictingProfile != nil)
        try store.resolveConflict(keepLocal: false)
        #expect(try store.draft()?.content?.favorites == [favorite])
        await store.synchronize(username: "reader")
        #expect(try store.draft()?.needsUpload == false)
    }

    @Test func failedUploadStaysQueuedThenSucceeds() async throws {
        let schema = Schema([ReaderProfileDraft.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let transport = ProfileFixtureTransport()
        let store = ReaderProfileStore(userID: UUID(), context: container.mainContext, transport: transport)
        try store.update(ReaderPersonality.summarize([], favorites: []))
        await transport.setFail(true)
        await store.synchronize(username: "reader")
        #expect(try store.draft()?.needsUpload == true)
        await transport.setFail(false)
        await store.synchronize(username: "reader")
        #expect(try store.draft()?.needsUpload == false)
        #expect(try store.draft()?.serverRevision == 1)
    }
}

private actor ProfileFixtureTransport: ReaderProfileTransport {
    var profile: PublicReaderProfile?
    var fail = false
    func setFail(_ fail: Bool) { self.fail = fail }
    func uploadAvatar(userID: UUID, path: String, data: Data) async throws { }
    func downloadAvatar(path: String) async throws -> Data { throw URLError(.fileDoesNotExist) }
    func fetch(username: String) async throws -> PublicReaderProfile? { profile }
    func publish(userID: UUID, revision: Int, content: ReaderPublicContent) async throws -> PublicReaderProfile {
        if fail { throw URLError(.notConnectedToInternet) }
        let saved = PublicReaderProfile(username: "reader", firstName: "Reader", memberSince: "2026-10-09", revision: revision + 1, content: content)
        profile = saved
        return saved
    }
}
