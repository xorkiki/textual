import Foundation
import SwiftData
import Supabase
import Testing
@testable import textual

@MainActor
struct AccountLibraryStoreTests {
    @Test func separateAccountsAndProjectsNeverShareTheSameLocalLibrary() throws {
        let setup = try fixture()
        defer { setup.cleanUp() }
        let firstID = UUID()
        let first = try setup.store(userID: firstID)
        let other = try setup.store(userID: UUID())
        let otherProject = try setup.store(userID: firstID, project: "another-project")
        try first.repository.add(Book(title: "Private first library", author: "Author", isbn: "OL1W",
                                      googleBooksVolumeId: "openlibrary:OL1W"))
        #expect(try first.container.mainContext.fetchCount(FetchDescriptor<Book>()) == 1)
        #expect(try other.container.mainContext.fetchCount(FetchDescriptor<Book>()) == 0)
        #expect(try otherProject.container.mainContext.fetchCount(FetchDescriptor<Book>()) == 0)
        #expect(try setup.legacy.mainContext.fetchCount(FetchDescriptor<Book>()) == 0)
    }

    @Test func legacyLibraryRequiresExplicitImportAndIsClaimedOnlyOnce() async throws {
        let setup = try fixture()
        defer { setup.cleanUp() }
        let original = Book(title: "Device book", author: "Author", isbn: "OL2W",
                            googleBooksVolumeId: "openlibrary:OL2W")
        setup.legacy.mainContext.insert(original)
        try setup.legacy.mainContext.save()
        let first = try setup.store(userID: UUID())
        #expect(first.legacyBookCount == 1)
        #expect(try first.container.mainContext.fetchCount(FetchDescriptor<Book>()) == 0)
        try await first.importLegacyLibrary()
        try await first.importLegacyLibrary()
        #expect(first.legacyBookCount == 0)
        let copies = try first.container.mainContext.fetch(FetchDescriptor<Book>())
        #expect(copies.count == 1)
        #expect(copies.first?.id != original.id)
        #expect(copies.first?.pendingOperationID != nil)
        #expect(try setup.legacy.mainContext.fetchCount(FetchDescriptor<Book>()) == 1)
        #expect(original.title == "Device book")
        let second = try setup.store(userID: UUID())
        #expect(second.legacyBookCount == 0)
        try await second.importLegacyLibrary()
        #expect(try second.container.mainContext.fetchCount(FetchDescriptor<Book>()) == 0)
    }

    @Test func stoppedAccountCannotImportIntoItsOldStore() async throws {
        let setup = try fixture()
        defer { setup.cleanUp() }
        setup.legacy.mainContext.insert(Book(title: "Device book", author: "Author", isbn: "OL3W",
                                             googleBooksVolumeId: "openlibrary:OL3W"))
        try setup.legacy.mainContext.save()
        let store = try setup.store(userID: UUID())
        store.repository.stop()
        await #expect(throws: LibraryRepositoryError.self) { try await store.importLegacyLibrary() }
        #expect(try store.container.mainContext.fetchCount(FetchDescriptor<Book>()) == 0)
        #expect(store.legacyBookCount == 1)
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "textual.account-store-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let schema = Schema([Book.self, Tag.self])
        let legacy = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let client = SupabaseClient(supabaseURL: URL(string: "https://account-store-tests.supabase.co")!,
                                    supabaseKey: "sb_publishable_account_store_tests")
        return Fixture(directory: directory, suite: suite, defaults: defaults, legacy: legacy, client: client)
    }

    private struct Fixture {
        let directory: URL
        let suite: String
        let defaults: UserDefaults
        let legacy: ModelContainer
        let client: SupabaseClient

        @MainActor func store(userID: UUID, project: String = "test-project") throws -> AccountLibraryStore {
            try AccountLibraryStore(userID: userID, client: client, legacyContainer: legacy,
                                    baseDirectory: directory, defaults: defaults, projectHost: project)
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
