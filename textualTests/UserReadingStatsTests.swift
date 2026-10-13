import Foundation
import SwiftData
import Testing
@testable import textual

@MainActor
struct UserReadingStatsTests {
    private func books() throws -> [Book] {
        let csv = """
        Title,Authors,ISBN/UID,Read Status,Date Added,Dates Read,Read Count,Moods,Pace
        First,Writer,9780140328721,read,2024/01/01,2025/01/01-2025/01/02,2,dark,fast
        Second,Writer,second,to-read,2024/02/01,,0,reflective,medium
        Third,Writer,third,did-not-finish,2024/03/01,,0,sad,slow
        """
        return try StoryGraphImporter.parse(Data(csv.utf8)).records.map { record in
            let book = Book(title: record.reading.originalFields["Title"] ?? "Fixture", author: "Writer", isbn: "9780140328721")
            book.storyGraphData = try JSONEncoder().encode(record.reading)
            book.cachedStatsClassification = try JSONEncoder().encode(BookCatalogService.ClassificationEvidence(
                categories: ["Fiction / Fantasy"], source: "google", editionPages: 240, editionISBN: "9780140328721"))
            return book
        }
    }

    @Test func allChartsUseSameStatusAndYearScope() throws {
        let books = try books()
        let all = UserReadingStats(books: books, filter: .init(status: "read", year: nil))
        #expect(all.totals.bookCount == 2)
        #expect(all.totals.pageCount == 480)
        #expect(all.totals.count(.fiction) == 2)
        #expect(all.genres.first { $0.name == "Fantasy" }?.count == 2)
        #expect(all.moods.first { $0.name == "Dark" }?.count == 2)
        #expect(all.paces.first { $0.pace == .fast }?.count == 2)
        #expect(all.averageDays == 2)
        let year = UserReadingStats(books: books, filter: .init(status: "read", year: 2025))
        #expect(year.totals.bookCount == 1)
        #expect(year.totals.pageCount == 240)
        #expect(year.genres.first?.count == 1)
        #expect(year.moods.first { $0.name == "Dark" }?.count == 1)
        #expect(year.paces.first { $0.pace == .fast }?.count == 1)
        for (status, mood, pace) in [("to-read", "Reflective", PaceStat.Pace.medium), ("did-not-finish", "Sad", .slow)] {
            let selection = UserReadingStats(books: books, filter: .init(status: status, year: nil))
            #expect(selection.totals.bookCount == 1)
            #expect(selection.totals.pageCount == 240)
            #expect(selection.genres.first?.count == 1)
            #expect(selection.moods.first { $0.name == mood }?.count == 1)
            #expect(selection.paces.first { $0.pace == pace }?.count == 1)
            #expect(selection.averageDays == nil)
        }
        let empty = UserReadingStats(books: books, filter: .init(status: "read", year: 2026))
        #expect(empty.totals.bookCount == 0 && empty.genres.isEmpty)
        #expect(empty.moods.allSatisfy { $0.count == 0 } && empty.paces.allSatisfy { $0.count == 0 })
    }

    @Test func missingAndMultipleLabelsDoNotDropReads() throws {
        let csv = """
        Title,Authors,ISBN/UID,Read Status,Date Added,Dates Read,Read Count,Moods,Pace
        Missing,Writer,one,read,2024/01/01,2025/01/01-2025/01/02,2,,
        Tagged,Writer,two,read,2024/01/01,2025/02/01-2025/02/02,1,"hopeful, lighthearted, hopeful",medium
        Outside,Writer,three,to-read,2024/01/01,,0,,
        """
        let books = try StoryGraphImporter.parse(Data(csv.utf8)).records.map { record in
            let book = Book(title: record.reading.originalFields["Title"] ?? "Fixture", author: "Writer", isbn: "")
            book.storyGraphData = try JSONEncoder().encode(record.reading)
            if book.title == "Tagged" {
                book.cachedStatsClassification = try JSONEncoder().encode(BookCatalogService.ClassificationEvidence(
                    categories: ["Fiction / Fantasy", "Fiction / Romance"], source: "google"))
            }
            return book
        }
        let all = UserReadingStats(books: books, filter: .init(status: "read", year: nil))
        #expect(all.totals.bookCount == 3)
        #expect(all.paces.reduce(0) { $0 + $1.count } == all.totals.bookCount)
        #expect(!all.paces.contains { $0.pace == .unknown })
        #expect(all.paces.first { $0.pace == .medium }?.estimatedCount == 2)
        #expect(all.paces.first { $0.pace == .medium }?.fraction(total: all.totals.bookCount) == 1.0)
        #expect(all.moods.first { $0.name == "Reflective" }?.count == 2)
        #expect(all.moods.first { $0.name == "Hopeful" }?.count == 1)
        #expect(all.moods.first { $0.name == "Lighthearted" }?.count == 1)
        #expect(all.genres.first { $0.name == "General fiction" }?.count == 2)
        #expect(all.genres.first { $0.name == "Fantasy" }?.count == 1)
        #expect(all.genres.first { $0.name == "Romance" }?.count == 1)
        let year = UserReadingStats(books: books, filter: .init(status: "read", year: 2025))
        #expect(year.totals.bookCount == 2)
        #expect(year.paces.first { $0.pace == .medium }?.estimatedCount == 1)
        #expect(year.moods.first { $0.name == "Reflective" }?.count == 1)
        #expect(year.genres.first { $0.name == "General fiction" }?.count == 1)
    }

    @Test func otherShelvesCannotMakeSelectedPageTotalsIncomplete() throws {
        let books = try books()
        books[1].cachedStatsClassification = nil
        books[2].cachedStatsClassification = nil
        let read = UserReadingStats(books: books, filter: .init(status: "read", year: nil))
        #expect(read.totals.completePages)
        #expect(read.totals.pageCount == 480)
        #expect(read.totals.entries.count == 1)
        let empty = UserReadingStats(books: books, filter: .init(status: "read", year: 2026))
        #expect(!empty.totals.hasPages && empty.totals.entries.isEmpty)
    }

    @Test func newCategoriesUpdateGenresWithoutReplacingImportOrEditionData() throws {
        let book = try #require(books().first)
        let imported = book.storyGraphData
        let old = try JSONSerialization.data(withJSONObject: ["id": "openlibrary:OL1W", "volumeInfo": ["categories": ["History"], "pageCount": 100]])
        book.cachedCatalogMetadata = old
        #expect(StatsMetadataCache.genres(book) == ["Fantasy"])
        #expect(StatsMetadataCache.pageCount(book) == 240)
        #expect(book.storyGraphData == imported)
        book.isbn = "9780439708180"
        #expect(StatsMetadataCache.pageCount(book) == 100) // Work-level categories cannot supply another edition's pages.
        book.cachedStatsClassification = try JSONEncoder().encode(BookCatalogService.ClassificationEvidence(categories: ["Poetry"], source: "google"))
        #expect(StatsMetadataCache.genres(book) == ["Poetry"])
        #expect(StatsMetadataCache.needsClassification(book, googleConfigured: true))
    }

    @Test func separateAccountsNeverShareReadingTotals() throws {
        let schema = Schema([Book.self, Tag.self])
        let first = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let second = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let firstBook = try #require(books().first)
        first.mainContext.insert(firstBook)
        try first.mainContext.save()
        let read = ReadingStatsFilter(status: "read", year: nil)
        let a = UserReadingStats(books: try first.mainContext.fetch(FetchDescriptor<Book>()), filter: read)
        let b = UserReadingStats(books: try second.mainContext.fetch(FetchDescriptor<Book>()), filter: read)
        #expect(a.totals.bookCount == 2 && a.totals.pageCount == 480)
        #expect(b.totals.bookCount == 0 && b.genres.isEmpty)
        #expect(b.moods.allSatisfy { $0.count == 0 } && b.paces.allSatisfy { $0.count == 0 })
        firstBook.isRemovedFromLibrary = true
        #expect(UserReadingStats(books: [firstBook], filter: read).totals.bookCount == 0)
    }

    @Test func genreOnlyEvidenceIsRetainedAndPagesRequireExactISBN() throws {
        func item(_ isbn: String) throws -> BookCatalogService.BookItem {
            let data = try JSONSerialization.data(withJSONObject: ["volumeInfo": ["title": "Poems", "authors": ["Writer"],
                "categories": ["Poetry"], "pageCount": 250, "industryIdentifiers": [["identifier": isbn]]]])
            return try JSONDecoder().decode(BookCatalogService.BookItem.self, from: data)
        }
        let wrongEdition = try item("9780439708180")
        let evidence = try #require(BookCatalogService.classificationEvidence([wrongEdition], isbn: "9780140328721", title: "Poems", author: "Writer", requireISBN: false))
        #expect(evidence.categories == ["Poetry"])
        #expect(evidence.editionPages == nil)
        let matching = try #require(BookCatalogService.classificationEvidence([try item("9780140328721")], isbn: "9780140328721", title: "Poems", author: "Writer", requireISBN: false))
        #expect(matching.editionPages == 250)
    }

    @Test func catalogMoodFallbackUpdatesChartsAndDrilldownsWithoutChangingImports() async throws {
        let csv = """
        Title,Authors,ISBN/UID,Read Status,Date Added,Dates Read,Read Count,Moods
        Estimated,Writer,one,read,2024/01/01,2025/01/01-2025/01/02,2,
        Imported,Writer,two,read,2024/01/01,2025/01/01-2025/01/02,1,hopeful
        Unknown,Writer,three,read,2024/01/01,2024/01/01-2024/01/02,1,
        Queued,Writer,four,to-read,2024/01/01,,0,
        """
        let books = try StoryGraphImporter.parse(Data(csv.utf8)).records.map { record in
            let book = Book(title: record.reading.originalFields["Title"]!, author: "Writer", isbn: "")
            book.storyGraphData = try JSONEncoder().encode(record.reading)
            if book.title != "Unknown" {
                book.cachedStatsClassification = try JSONEncoder().encode(BookCatalogService.ClassificationEvidence(
                    categories: ["Fiction"], source: "google", openLibraryCategories: ["Horror fiction", "Suspense fiction"]))
            }
            return book
        }
        let originals = books.map(\.storyGraphData)
        let all = ReadingStatsFilter(status: "read", year: nil)
        let stats = UserReadingStats(books: books, filter: all)
        #expect(stats.moods.first { $0.name == "Dark" }?.count == 2)
        #expect(stats.moods.first { $0.name == "Dark" }?.estimatedCount == 2)
        #expect(stats.moods.first { $0.name == "Hopeful" }?.estimatedCount == 0)
        #expect(stats.moods.first { $0.name == "Reflective" }?.count == 1)
        for mood in stats.moods {
            let matches = StatsBookCategory.mood(mood.name).books(in: books, filter: all)
            #expect(matches.reduce(0) { $0 + all.count($1.importedReading!) } == mood.count)
        }
        let year = UserReadingStats(books: books, filter: .init(status: "read", year: 2025))
        #expect(year.moods.first { $0.name == "Dark" }?.estimatedCount == 1)
        let queued = UserReadingStats(books: books, filter: .init(status: "to-read", year: nil))
        #expect(queued.moods.first { $0.name == "Dark" }?.estimatedCount == 1)
        #expect(books.map(\.storyGraphData) == originals)

        let worker = ReadingLibraryWorker()
        _ = try await worker.prepare(books.map(ReadingBookInput.init))
        let estimated = try #require(books.first { $0.title == "Estimated" })
        estimated.cachedStatsClassification = try JSONEncoder().encode(BookCatalogService.ClassificationEvidence(
            categories: ["Fiction / Humorous"], source: "google"))
        let updated = try await worker.prepare(books.map(ReadingBookInput.init))
        let refreshed = await worker.stats(for: updated, filter: all)
        #expect(refreshed.moods.first { $0.name == "Funny" }?.estimatedCount == 2)
        #expect(refreshed.moods.first { $0.name == "Dark" }?.count == 0)
    }

    @Test func catalogMetadataCanSupplyMoodsBeforeClassificationArrives() throws {
        let book = try #require(books().first)
        // An imported assessment still wins over metadata, even before enrichment.
        book.cachedStatsClassification = nil
        book.cachedCatalogMetadata = try JSONSerialization.data(withJSONObject: ["id": "volume", "volumeInfo": ["mainCategory": "Fiction / Humorous"]])
        let entry = ReadingBookSnapshot(ReadingBookInput(book))
        #expect(entry.catalogMoods.moods == ["funny"])
        #expect(entry.moods?.value == ["dark"] && entry.moods?.source == .imported)
    }

    @Test func guessesFillEveryMissingFieldAndAreReplacedByCatalogFacts() async throws {
        let book = try #require(books().first)
        book.cachedStatsClassification = nil
        let initial = ReadingBookSnapshot(ReadingBookInput(book))
        #expect(initial.kind == nil && initial.genres.isEmpty)
        #expect(initial.statsKind == .fiction && initial.statsGenres == ["General fiction"])
        #expect(initial.guess.kindReason?.hasPrefix("Low-confidence") == true)
        #expect(initial.moods?.value == ["dark"] && initial.moodEstimateReason == nil)
        #expect(StatsMetadataCache.needsClassification(book))
        let original = book.storyGraphData
        let worker = ReadingLibraryWorker()
        let before = try await worker.prepare([ReadingBookInput(book)])
        #expect(await worker.stats(for: before, filter: .init(status: "read", year: nil)).totals.unclassifiedCount == 0)
        book.cachedStatsClassification = try JSONEncoder().encode(BookCatalogService.ClassificationEvidence(
            categories: ["Nonfiction / Biography"], source: "google"))
        let after = try await worker.prepare([ReadingBookInput(book)])
        let updated = try #require(after.entries.first)
        #expect(updated.statsKind == .nonfiction && updated.statsGenres == ["Biography"])
        #expect(updated.guess.kindReason == nil && updated.guess.genreReason == nil)
        #expect(book.storyGraphData == original)
    }

    @Test func descriptionGenreAndTitleFallbacksKeepTheirProvenance() {
        func guess(_ title: String = "Unfamiliar Book", _ categories: [String] = [], _ context: [String] = [], kind: BookFictionKind? = nil, genres: Set<String> = []) -> CatalogStatsGuess {
            CatalogStatsGuess(title: title, categories: categories, context: context, knownKind: kind,
                              knownGenres: genres, directMoods: CatalogMoodEstimate(categories: categories))
        }
        let novel = guess("Unfamiliar Book", [], ["A novel", "<p>A heartwarming, hopeful romance.</p>"])
        #expect(novel.kind == .fiction && novel.genres.contains("Romance"))
        #expect(novel.moods == ["hopeful"])
        #expect(novel.kindReason?.contains("catalog context") == true)
        let memoir = guess("Unfamiliar Book", [], ["An inspiring memoir of a scientist."])
        #expect(memoir.kind == .nonfiction && memoir.genres.contains("Memoir"))
        #expect(memoir.moods == ["inspiring"])
        let fantasy = guess("Unfamiliar Book", ["Fiction / Fantasy"], [], kind: .fiction, genres: ["Fantasy"])
        #expect(fantasy.moods == ["adventurous"] && fantasy.moodReason.contains("genre"))
        let nonfiction = guess("Unfamiliar Book", ["Nonfiction / Science"], [], kind: .nonfiction, genres: ["Science"])
        #expect(nonfiction.moods == ["informative"] && nonfiction.moodReason.hasPrefix("Low-confidence"))
        let title = guess("A Memoir")
        #expect(title.kind == .nonfiction && title.kindReason?.contains("title") == true)
        let missing = guess()
        #expect(!missing.genres.isEmpty && !missing.moods.isEmpty)
        #expect(missing.kindReason?.hasPrefix("Low-confidence default") == true)
        #expect(missing.moodReason.hasPrefix("Low-confidence"))
        let authoritative = guess("A Memoir", ["Fiction / Fantasy"], ["biography"], kind: .fiction, genres: ["Fantasy"])
        #expect(authoritative.kind == .fiction && authoritative.genres == ["Fantasy"])
        #expect(authoritative.kindReason == nil && authoritative.genreReason == nil)
    }

    @Test func estimatedPaceAndPagesStayConsistentAcrossChartsListsAndRefresh() async throws {
        let csv = """
        Title,Authors,ISBN/UID,Read Status,Date Added,Dates Read,Read Count,Pace
        Estimated,Writer,one,read,2024/01/01,2025/01/01-2025/01/02,2,
        Recorded,Writer,two,read,2024/01/01,2025/01/01-2025/01/02,1,slow
        Queued,Writer,three,to-read,2024/01/01,,0,
        """
        let books = try StoryGraphImporter.parse(Data(csv.utf8)).records.map { record in
            let book = Book(title: record.reading.originalFields["Title"]!, author: "Writer", isbn: "9780140328721")
            book.storyGraphData = try JSONEncoder().encode(record.reading)
            book.cachedStatsClassification = try JSONEncoder().encode(BookCatalogService.ClassificationEvidence(
                categories: ["Fiction / Thriller"], source: "google", context: ["Fast-paced"], workPageCounts: [280, 320]))
            return book
        }
        let recorded = try #require(books.first { $0.title == "Recorded" })
        recorded.cachedCatalogMetadata = try JSONSerialization.data(withJSONObject: ["id": "volume", "volumeInfo": ["pageCount": 240]])
        let original = books.map(\.storyGraphData)
        let all = ReadingStatsFilter(status: "read", year: nil)
        let stats = UserReadingStats(books: books, filter: all)
        #expect(stats.totals.pageCount == 840 && stats.totals.estimatedPageReads == 2)
        #expect(!stats.totals.completePages && stats.totals.pageTotalDetail == "Includes estimates")
        #expect(stats.paces.first { $0.pace == .fast }?.estimatedCount == 2)
        #expect(stats.paces.first { $0.pace == .slow }?.estimatedCount == 0)
        #expect(stats.paces.reduce(0) { $0 + $1.count } == 3)
        #expect(StatsBookCategory.pace(.fast).books(in: books, filter: all).map(\.title) == ["Estimated"])
        #expect(StatsBookCategory.pages.books(in: books, filter: all).map(\.title) == ["Estimated", "Recorded"])
        let year = UserReadingStats(books: books, filter: .init(status: "read", year: 2025))
        #expect(year.totals.pageCount == 540 && year.totals.estimatedPageReads == 1)
        #expect(year.totals.buckets[0].knownPages == 1 && year.totals.buckets[0].estimatedPages == 1)
        let queued = UserReadingStats(books: books, filter: .init(status: "to-read", year: nil))
        #expect(queued.totals.pageCount == 300 && queued.paces.first { $0.pace == .fast }?.count == 1)
        let estimated = try #require(books.first { $0.title == "Estimated" })
        #expect(StatsMetadataCache.pageCount(estimated) == nil)
        let worker = ReadingLibraryWorker()
        _ = try await worker.prepare(books.map(ReadingBookInput.init))
        estimated.cachedStatsClassification = try JSONEncoder().encode(BookCatalogService.ClassificationEvidence(
            categories: ["Fiction / Thriller"], source: "google", editionPages: 410, editionISBN: estimated.isbn,
            context: ["Slow-paced"], workPageCounts: [280, 320]))
        let changed = try await worker.prepare(books.map(ReadingBookInput.init))
        let refreshed = await worker.stats(for: changed, filter: all)
        #expect(refreshed.totals.pageCount == 1060 && refreshed.totals.completePages)
        #expect(refreshed.paces.first { $0.pace == .slow }?.count == 3)
        #expect(books.map(\.storyGraphData) == original)
    }

}
