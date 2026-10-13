import Foundation
import Testing
@testable import textual

struct FictionStatsTests {
    @Test func classificationUsesExplicitSubjects() {
        #expect(BookFictionKind.classify(["Fiction / Literary"]) == .fiction)
        #expect(BookFictionKind.classify(["Science fiction"]) == .fiction)
        #expect(BookFictionKind.classify(["Non-fiction"]) == .nonfiction)
        #expect(BookFictionKind.classify(["Biography & Autobiography"]) == .nonfiction)
        #expect(BookFictionKind.classify(["History / Europe"]) == .nonfiction)
    }
    @Test func unknownAndConflictingSubjectsStayUnknown() {
        #expect(BookFictionKind.classify([]) == nil)
        #expect(BookFictionKind.classify(["New York", "Love"]) == nil)
        #expect(BookFictionKind.classify(["Fiction", "Nonfiction"]) == nil)
        #expect(BookFictionKind.classify(["Fiction / Fantasy", "Nonfiction"]) == nil)
        #expect(BookFictionKind.classify(["Fiction", "Nonfiction / History"]) == nil)
        #expect(BookFictionKind.classify(["Literary criticism / Science fiction"]) == .nonfiction)
    }
    @Test func topicalSubjectsDoNotOverrideFormalFictionCategories() {
        #expect(BookFictionKind.classify(["History", "FICTION / Fantasy / Historical"]) == .fiction)
        #expect(BookFictionKind.classify(["Science and magic", "Fiction"]) == .fiction)
        #expect(BookFictionKind.classify(["Fantasy", "Card Games"]) == .fiction)
        #expect(BookFictionKind.classify(["Fiction", "Biography", "nyt:combined-print-and-e-book-nonfiction=2012-05-06"]) == .nonfiction)
        #expect(BookFictionKind.classify(["Self-realization", "Conduct of life"]) == .nonfiction)
        #expect(BookFictionKind.classify(["Juvenile Nonfiction / History"]) == .nonfiction)
    }

    @Test func classificationRequiresVerifiedIdentityAndRejectsConflictingEditions() throws {
        func item(_ title: String, _ author: String, _ category: String, _ isbn: String = "9780140328721") throws -> BookCatalogService.BookItem {
            let data = try JSONSerialization.data(withJSONObject: ["volumeInfo": ["title": title,
                "authors": [author], "categories": [category],
                "industryIdentifiers": [["type": "ISBN_13", "identifier": isbn]]]])
            return try JSONDecoder().decode(BookCatalogService.BookItem.self, from: data)
        }
        let correct = try item("Matilda", "Roald Dahl", "Juvenile Fiction")
        let unrelated = try item("Matilda", "Another Author", "History", "9780439708180")
        #expect(BookCatalogService.classificationEvidence([unrelated, correct], isbn: "0140328726", title: "", author: "", requireISBN: true)?.categories == ["Juvenile Fiction"])
        #expect(BookCatalogService.classificationEvidence([unrelated], isbn: nil, title: "Matilda", author: "Roald Dahl", requireISBN: false) == nil)
        #expect(BookCatalogService.classificationEvidence([correct], isbn: nil, title: "Matilda", author: "Roald Dahl", requireISBN: false)?.source == "google")
        #expect(BookCatalogService.classificationEvidence([correct, try item("Matilda", "Roald Dahl", "Nonfiction")], isbn: nil, title: "Matilda", author: "Roald Dahl", requireISBN: false) == nil)
        #expect(!BookCatalogService.matchesWork(try item("Series: Second Book", "Writer", "Fiction"), title: "Series: First Book", author: "Writer"))
    }

    @Test @MainActor func incompleteCategoriesStillTriggerClassificationAndFallbackCanRetry() throws {
        let book = Book(title: "Example", author: "Writer", isbn: "")
        let now = Date()
        #expect(StatsMetadataCache.needsClassification(book, now: now))
        book.cachedStatsClassification = try JSONEncoder().encode(BookCatalogService.ClassificationEvidence(categories: ["Fantasy"], source: "openlibrary"))
        book.statsClassificationCheckedAt = now
        book.statsClassificationVersion = StatsMetadataCache.classificationVersion
        #expect(StatsMetadataCache.fictionKind(book) == .fiction)
        #expect(!StatsMetadataCache.needsClassification(book, now: now))
        #expect(StatsMetadataCache.needsClassification(book, googleConfigured: true, now: now))
        book.statsClassificationUsedGoogleKey = true
        book.statsClassificationVersion = StatsMetadataCache.classificationVersion
        #expect(!StatsMetadataCache.needsClassification(book, googleConfigured: true, now: now))
        #expect(!StatsMetadataCache.needsClassification(book, now: now.addingTimeInterval(86_401)))
        book.cachedStatsClassification = try JSONEncoder().encode(BookCatalogService.ClassificationEvidence(categories: ["Fiction"], source: "google"))
        #expect(StatsMetadataCache.needsClassification(book, now: now.addingTimeInterval(86_401)))
    }

    @Test func supplementalCatalogSubjectsCannotOverrideConflictingClassification() {
        let original = BookCatalogService.ClassificationEvidence(categories: ["Fiction"], source: "google")
        let conflicting = BookCatalogService.ClassificationEvidence(categories: ["Nonfiction", "History"], source: "openlibrary")
        let result = original.supplemented(with: conflicting)
        #expect(result.fictionKind == .fiction)
        #expect(result.genres.isEmpty)
        #expect(result.openLibraryCategories == nil)
    }

    @Test @MainActor func oldBroadCacheRefreshesOnceThenUsesDailyBackoff() throws {
        let book = Book(title: "Example", author: "Writer", isbn: "")
        book.cachedStatsClassification = try JSONEncoder().encode(BookCatalogService.ClassificationEvidence(categories: ["Fiction"], source: "google"))
        let now = Date(); book.statsClassificationCheckedAt = now
        book.statsClassificationVersion = 1; book.statsClassificationUsedGoogleKey = true
        #expect(StatsMetadataCache.needsClassification(book, googleConfigured: true, now: now))
        book.statsClassificationVersion = StatsMetadataCache.classificationVersion
        #expect(!StatsMetadataCache.needsClassification(book, googleConfigured: true, now: now))
        #expect(StatsMetadataCache.needsClassification(book, googleConfigured: true, now: now.addingTimeInterval(86401)))
    }

    @Test func classifiedAndUnclassifiedReadsAlwaysReconcile() {
        let data = ReadingStatsSnapshot(entries: [.init(dates: [], count: 47, pages: nil, kind: .fiction),
                                                .init(dates: [], count: 11, pages: nil, kind: .nonfiction),
                                                .init(dates: [], count: 34, pages: nil, kind: nil)], year: nil)
        #expect(data.unclassifiedCount == 34)
        #expect(data.count(.fiction) + data.count(.nonfiction) + data.unclassifiedCount == data.bookCount)
    }

    @Test func sharedFilterRespectsStatusYearAndUndatedHistory() throws {
        var row = StoryGraphImportTests.row
        let reading = try #require(StoryGraphImporter.parse(StoryGraphImportTests.csv([row])).records.first).reading
        #expect(ReadingStatsFilter(status: "read", year: nil).includes(reading))
        #expect(ReadingStatsFilter(status: "read", year: 2025).dates(for: reading).count == 1)
        #expect(!ReadingStatsFilter(status: "read", year: 2026).includes(reading))
        #expect(!ReadingStatsFilter(status: "to-read", year: nil).includes(reading))
        row[5] = ""
        let undated = try #require(StoryGraphImporter.parse(StoryGraphImportTests.csv([row])).records.first).reading
        #expect(ReadingStatsFilter(status: "read", year: nil).includes(undated))
        #expect(!ReadingStatsFilter(status: "read", year: 2025).includes(undated))
        row[3] = "to-read"
        let tbr = try #require(StoryGraphImporter.parse(StoryGraphImportTests.csv([row])).records.first).reading
        #expect(ReadingStatsFilter(status: "to-read", year: 2024).includes(tbr))
        #expect(!ReadingStatsFilter(status: "to-read", year: 2025).includes(tbr))
    }
    @Test func yearlyAndMonthlyTotalsDoNotInventDatesOrPages() throws {
        let calendar = Calendar(identifier: .gregorian)
        let january = try #require(calendar.date(from: DateComponents(year: 2025, month: 1, day: 2)))
        let may = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 2)))
        let entries: [ReadingStatsSnapshot.Entry] = [
            .init(dates: [january, may], count: 2, pages: 200, kind: .fiction),
            .init(dates: [january], count: 1, pages: nil, kind: .nonfiction),
            .init(dates: [], count: 1, pages: 100, kind: .fiction)
        ]
        let all = ReadingStatsSnapshot(entries: entries, year: nil)
        #expect(all.bookCount == 4)
        #expect(all.pageCount == 500)
        #expect(!all.completePages)
        #expect(all.count(.fiction) == 3)
        #expect(all.buckets.map(\.books) == [2, 1])
        #expect(all.buckets.map(\.pages) == [200, 200])
        let yearly = ReadingStatsSnapshot(entries: entries, year: 2025)
        #expect(yearly.buckets.count == 12)
        #expect(yearly.buckets[0].books == 2)
        #expect(yearly.buckets[0].knownPages == 1)
        #expect(yearly.buckets.dropFirst().allSatisfy { $0.books == 0 })
        #expect(ReadingStatsSnapshot(entries: [], year: nil).buckets.isEmpty)
    }

    @Test func pageCountDecodesWithoutBreakingOldCaches() throws {
        let old = Data(#"{"id":"old","volumeInfo":{"title":"Book"}}"#.utf8)
        let new = Data(#"{"id":"new","volumeInfo":{"title":"Book","pageCount":320}}"#.utf8)
        #expect(try JSONDecoder().decode(BookCatalogService.BookItem.self, from: old).volumeInfo?.pageCount == nil)
        #expect(try JSONDecoder().decode(BookCatalogService.BookItem.self, from: new).volumeInfo?.pageCount == 320)
    }
    @Test func finishAverageUsesValidPairedDatesAndSelectedFinishYear() throws {
        var row = StoryGraphImportTests.row
        row[5] = "2024/12/30-2025/01/02, 2025/03/01-2025/03/01, 2026/01/01-2026/01/10, -2025/04/01, 2025/05/05-2025/05/01"
        let reading = try #require(StoryGraphImporter.parse(StoryGraphImportTests.csv([row])).records.first).reading
        #expect(ReadingStatsFilter(status: "read", year: 2025).averageDaysToFinish([reading]) == 2.5)
        #expect(ReadingStatsFilter(status: "read", year: nil).averageDaysToFinish([reading]) == 5)
        #expect(ReadingStatsFilter(status: "read", year: 2024).averageDaysToFinish([reading]) == nil)
        #expect(ReadingStatsFilter(status: "to-read", year: nil).averageDaysToFinish([reading]) == nil)
        #expect(ReadingStatsFilter(status: "read", year: nil).averageDaysToFinish([]) == nil)
    }
    @Test @MainActor func cacheKeepsCompletedMetadataAndBacksOffMissingLookups() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(!StatsMetadataCache.needsLookup(hasCategories: true, hasPages: true, isAudio: false, checkedAt: nil, now: now))
        #expect(StatsMetadataCache.needsLookup(hasCategories: true, hasPages: false, isAudio: true, checkedAt: nil, now: now))
        #expect(StatsMetadataCache.needsLookup(hasCategories: false, hasPages: false, isAudio: false, checkedAt: nil, now: now))
        #expect(!StatsMetadataCache.needsLookup(hasCategories: false, hasPages: false, isAudio: false, checkedAt: now.addingTimeInterval(-60), now: now))
        #expect(StatsMetadataCache.needsLookup(hasCategories: false, hasPages: false, isAudio: false, checkedAt: now.addingTimeInterval(-86_401), now: now))
    }
    @Test func previousReadsSurviveEveryCurrentStatus() throws {
        let read = ReadingStatsFilter(status: "read", year: nil)
        for status in ["read", "to-read", "currently-reading", "did-not-finish"] {
            var row = StoryGraphImportTests.row
            row[3] = status; row[5] = ""; row[6] = "2"
            let record = try #require(StoryGraphImporter.parse(StoryGraphImportTests.csv([row])).records.first)
            #expect(read.includes(record.reading))
            #expect(read.count(record.reading) == 2)
            #expect(!ReadingStatsFilter(status: "read", year: 2025).includes(record.reading))
        }
    }
    @Test func undatedRereadsAndOtherShelvesReconcileAllTimeTotal() throws {
        var rows: [[String]] = []
        for index in 0..<88 {
            var row = StoryGraphImportTests.row
            row[0] = "Fixture \(index)"; row[2] = "fixture-\(index)"; row[5] = ""
            row[3] = index < 85 ? "read" : (index == 87 ? "did-not-finish" : "to-read")
            row[6] = index == 0 ? "4" : (index == 1 ? "2" : "1")
            rows.append(row)
        }
        let document = try StoryGraphImporter.parse(StoryGraphImportTests.csv(rows))
        #expect(document.records.reduce(0) { $0 + ReadingStatsFilter(status: "read", year: nil).count($1.reading) } == 92)
    }
    @Test func sameDayRereadsRemainDistinctAndDNFDatesDoNotBecomeCompletions() throws {
        var row = StoryGraphImportTests.row
        row[5] = "2025/01/01-2025/01/01, 2025/01/01-2025/01/01"; row[6] = "2"
        let reading = try #require(StoryGraphImporter.parse(StoryGraphImportTests.csv([row])).records.first).reading
        #expect(ReadingStatsFilter(status: "read", year: 2025).count(reading) == 2)
        #expect(ReadingStatsFilter(status: "read", year: nil).averageDaysToFinish([reading]) == 1)
        row[3] = "did-not-finish"; row[6] = "0"
        let dnf = try #require(StoryGraphImporter.parse(StoryGraphImportTests.csv([row])).records.first).reading
        #expect(!ReadingStatsFilter(status: "read", year: nil).includes(dnf))
        #expect(ReadingStatsFilter(status: "did-not-finish", year: nil).count(dnf) == 1)
        #expect(!ReadingStatsFilter(status: "did-not-finish", year: 2025).includes(dnf))
    }
    @Test func pageFallbackRequiresMatchingEditionAndRejectsConflicts() throws {
        func item(_ isbn: String, _ pages: Int) throws -> BookCatalogService.BookItem {
            let data = try JSONSerialization.data(withJSONObject: ["volumeInfo": ["pageCount": pages,
                "industryIdentifiers": [["type": "ISBN_13", "identifier": isbn]]]])
            return try JSONDecoder().decode(BookCatalogService.BookItem.self, from: data)
        }
        let correct = try item("9780140328721", 240)
        let other = try item("9780439708180", 999)
        #expect(BookCatalogService.exactEditionPageCount(items: [other, correct], isbn: "0-14-032872-6") == 240)
        #expect(BookCatalogService.exactEditionPageCount(items: [other], isbn: "9780140328721") == nil)
        #expect(BookCatalogService.exactEditionPageCount(items: [correct, try item("9780140328721", 300)], isbn: "9780140328721") == nil)
    }
}
