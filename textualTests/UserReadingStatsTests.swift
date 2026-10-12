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
        #expect(all.paces.first { $0.pace == .unknown }?.count == 2)
        #expect(all.paces.first { $0.pace == .medium }?.fraction(total: all.totals.bookCount) == 1.0 / 3)
        #expect(all.moods.first { $0.name == "Not recorded" }?.count == 2)
        #expect(all.moods.first { $0.name == "Hopeful" }?.count == 1)
        #expect(all.moods.first { $0.name == "Lighthearted" }?.count == 1)
        #expect(all.genres.first { $0.name == "Unclassified" }?.count == 2)
        #expect(all.genres.first { $0.name == "Fantasy" }?.count == 1)
        #expect(all.genres.first { $0.name == "Romance" }?.count == 1)
        let year = UserReadingStats(books: books, filter: .init(status: "read", year: 2025))
        #expect(year.totals.bookCount == 2)
        #expect(year.paces.first { $0.pace == .unknown }?.count == 1)
        #expect(year.moods.first { $0.name == "Not recorded" }?.count == 1)
        #expect(year.genres.first { $0.name == "Unclassified" }?.count == 1)
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
        #expect(!StatsMetadataCache.needsClassification(book, googleConfigured: true))
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
}
