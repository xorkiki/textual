import Foundation
import SwiftData
import Testing
@testable import textual

@MainActor
struct ReadingLibraryCacheTests {
    private func book(_ name: String = "Fixture", status: String = "read", reads: Int = 2) throws -> Book {
        let book = Book(title: name, author: "Writer", isbn: "9780140328721")
        book.storyGraphData = try JSONEncoder().encode(StoryGraphReadingData(sourceKey: name, status: status,
            dateAdded: "2024-01-01", lastDateRead: "2025-02-02",
            periods: [.init(startedOn: "2025-02-01", finishedOn: "2025-02-02")], readCount: reads,
            rating: nil, format: "paperback", moods: ["dark"], pace: "fast", tags: [], owned: nil, originalFields: [:]))
        book.cachedStatsClassification = try JSONEncoder().encode(BookCatalogService.ClassificationEvidence(
            categories: ["Fiction / Fantasy"], source: "google", editionPages: 240, editionISBN: book.isbn))
        return book
    }

    @Test func backgroundSnapshotPreservesScopeAndUpdatesAfterEditsAndRemoval() async throws {
        let first = try book(), second = try book("Second", status: "to-read", reads: 0)
        let worker = ReadingLibraryWorker()
        let snapshot = try await worker.prepare([first, second].map(ReadingBookInput.init))
        #expect(snapshot.profile.stats.reads == 2)
        #expect(snapshot.years == [2025, 2024])
        #expect(snapshot.archive.matching(.init(genre: "Fantasy", mood: "Dark", pace: "Fast")) == [first.id])
        #expect(snapshot.archive.matching(.init(status: .all), search: "second") == [second.id])
        let all = await worker.stats(for: snapshot, filter: .init(status: "read", year: nil))
        #expect(all.totals.bookCount == 2 && all.totals.pageCount == 480)
        let year = await worker.stats(for: snapshot, filter: .init(status: "read", year: 2025))
        #expect(year.totals.bookCount == 1 && year.averageDays == 2)
        first.cachedStatsClassification = nil
        let changed = try await worker.prepare([ReadingBookInput(first)])
        let next = await worker.stats(for: changed, filter: .init(status: "read", year: nil))
        #expect(next.totals.estimatedPageReads == 2 && next.genres.first?.name == "General fiction")
        #expect(changed.archive.matching(.init(status: .tbr)).isEmpty)
        // Old in-flight consumers can finish, but cannot contaminate a newer cache key.
        _ = await worker.stats(for: snapshot, filter: .init(status: "read", year: nil))
        #expect(await worker.stats(for: changed, filter: .init(status: "read", year: nil)).totals.pageCount == 640)
    }

    @Test func cancelledPreparationAndSeparateAccountsDoNotReplaceVisibleData() async throws {
        let cache = ReadingLibraryCache()
        let input = ReadingBookInput(try book())
        await cache.update([input])
        let pending = Task { await cache.update([]) }
        pending.cancel()
        await pending.value
        #expect(cache.snapshot.entries.count == 1)
        let other = ReadingLibraryCache()
        await other.update([])
        #expect(other.snapshot.entries.isEmpty && other.profile.stats.reads == 0)
        #expect(cache.profile.stats.reads == 2)
    }

    @Test func archiveAndQueueSnapshotsMatchExistingRules() async throws {
        let books = try [book("One"), book("Two", status: "currently-reading"), book("Three", status: "to-read")]
        for (index, book) in books.enumerated() {
            var reading = try #require(book.importedReading)
            reading.upNextPosition = 2 - index
            book.storyGraphData = try JSONEncoder().encode(reading)
        }
        let worker = ReadingLibraryWorker()
        let snapshot = try await worker.prepare(books.map(ReadingBookInput.init))
        #expect(snapshot.queue == UpNextQueue.books(in: books).map(\.id))
        #expect(snapshot.currentlyReading == [books[1].id])
        let old = ArchiveFilterCatalog(books: books)
        #expect(snapshot.archive.options == old.options)
        for status in ArchiveReadingStatus.allCases {
            let filter = ArchiveFilter(status: status, genre: "Fantasy")
            #expect(snapshot.archive.matching(filter) == Set(old.books(matching: filter).map(\.id)))
        }
    }

    @Test func historyMemoizationInvalidatesForEditsMissingDataAndRollback() throws {
        let book = try book()
        let original = book.storyGraphData
        #expect(book.importedReading?.readCount == 2)
        book.storyGraphData = Data("invalid".utf8)
        #expect(book.importedReading == nil)
        book.storyGraphData = nil
        #expect(book.importedReading == nil)
        book.storyGraphData = original
        #expect(book.importedReading?.readCount == 2)
    }

    @Test func largeLibraryReusesPreparedStats() async throws {
        let books = try (0..<1_000).map { try book("Book \($0)") }
        let inputs = books.map(ReadingBookInput.init)
        let worker = ReadingLibraryWorker()
        let clock = ContinuousClock()
        let start = clock.now
        let snapshot = try await worker.prepare(inputs)
        let filter = ReadingStatsFilter(status: "read", year: nil)
        let first = await worker.stats(for: snapshot, filter: filter)
        let preparation = start.duration(to: clock.now)
        let repeatStart = clock.now
        for _ in 0..<20 {
            let cached = await worker.stats(for: snapshot, filter: filter)
            #expect(cached.totals.bookCount == 2_000 && cached.totals.pageCount == 480_000)
        }
        print("Reading cache: 1000 books prepare+stats=\(preparation); 20 cached reads=\(repeatStart.duration(to: clock.now))")
        #expect(first.moods.first { $0.name == "Dark" }?.count == 2_000)
    }
}
