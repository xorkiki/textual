import Foundation
import Testing
@testable import textual

@MainActor
struct StatsCategoryBooksTests {
    private func fixtures() throws -> [Book] {
        let csv = """
        Title,Authors,ISBN/UID,Read Status,Date Added,Dates Read,Read Count,Moods,Pace
        Tagged,Writer,one,to-read,2024/01/01,2025/01/01-2025/01/02,2,"Dark, dark, hopeful",fast
        Missing,Writer,two,read,2024/01/01,2025/02/01-2025/02/02,1,,unrecognized
        Earlier,Writer,three,read,2024/01/01,2024/02/01-2024/02/02,1,dark,medium
        Unfinished,Writer,four,did-not-finish,2024/01/01,,0,sad,slow
        Removed,Writer,five,read,2024/01/01,2025/02/01-2025/02/02,1,dark,fast
        """
        return try StoryGraphImporter.parse(Data(csv.utf8)).records.map { record in
            let title = record.reading.originalFields["Title"] ?? "Fixture"
            let book = Book(title: title, author: "Writer", isbn: "")
            book.storyGraphData = try JSONEncoder().encode(record.reading)
            if title != "Missing" {
                book.cachedStatsClassification = try JSONEncoder().encode(BookCatalogService.ClassificationEvidence(
                    categories: title == "Earlier" ? ["Nonfiction / History"] : ["Fiction / Fantasy", "Fiction / Romance"], source: "google"))
            }
            book.isRemovedFromLibrary = title == "Removed"
            return book
        }
    }

    @Test func everyCategoryReturnsExactlyTheBooksContributingToItsCount() throws {
        let books = try fixtures()
        for filter in [ReadingStatsFilter(status: "read", year: nil), .init(status: "read", year: 2025),
                       .init(status: "to-read", year: 2024), .init(status: "did-not-finish", year: nil)] {
            let stats = UserReadingStats(books: books, filter: filter)
            let snapshots = Dictionary(uniqueKeysWithValues: books.map { ($0.id, ReadingBookSnapshot(ReadingBookInput($0))) })
            let categories: [(StatsBookCategory, Int)] = BookFictionKind.allCases.map { (.fiction($0), stats.totals.count($0)) }
                + [(.fiction(nil), stats.totals.unclassifiedCount), (.pages, stats.totals.bookCount)]
                + stats.moods.map { (.mood($0.name), $0.count) }
                + stats.paces.map { (.pace($0.pace), $0.count) }
                + stats.genres.map { (.genre($0.name), $0.count) }
            for (category, count) in categories {
                let matches = category.books(in: books, filter: filter)
                #expect(matches.compactMap(\.importedReading).reduce(0) { $0 + filter.count($1) } == count)
                #expect(!matches.contains { $0.isRemovedFromLibrary })
                #expect(category.books(in: books, filter: filter, snapshots: snapshots).map(\.id) == matches.map(\.id))
            }
        }
    }

    @Test func resultsRespectHistoryYearMissingMetadataAndUniqueBooks() throws {
        let books = try fixtures()
        let all = ReadingStatsFilter(status: "read", year: nil)
        let year = ReadingStatsFilter(status: "read", year: 2025)
        #expect(StatsBookCategory.mood("Dark").books(in: books, filter: all).map(\.title) == ["Earlier", "Tagged"])
        #expect(StatsBookCategory.mood("Dark").books(in: books, filter: year).map(\.title) == ["Tagged"])
        #expect(StatsBookCategory.mood("Hopeful").books(in: books, filter: year).map(\.title) == ["Tagged"])
        for category in [StatsBookCategory.mood("Reflective"), .pace(.medium), .genre("General fiction")] {
            #expect(category.books(in: books, filter: year).map(\.title) == ["Missing"])
        }
        for category in [StatsBookCategory.genre("Fantasy"), .genre("Romance"), .pace(.fast)] {
            #expect(category.books(in: books + books, filter: all).map(\.title) == ["Tagged"])
            #expect(category.books(in: books, filter: .init(status: "read", year: 2026)).isEmpty)
        }
        #expect(StatsBookCategory.fiction(.fiction).books(in: books + books, filter: all).map(\.title) == ["Missing", "Tagged"])
        #expect(StatsBookCategory.fiction(nil).books(in: books, filter: all).isEmpty)
        #expect(StatsBookCategory.mood("Not recorded").books(in: books, filter: all).isEmpty)
        #expect(StatsBookCategory.fiction(.nonfiction).books(in: books, filter: all).map(\.title) == ["Earlier"])
        #expect(StatsBookCategory.mood("Sad").books(in: books, filter: .init(status: "did-not-finish", year: nil)).map(\.title) == ["Unfinished"])
    }

    @Test func sectorHitTestingSkipsEmptySlicesAndHandlesBoundaries() {
        let counts = [0, 2, 0, 3, 1]
        #expect(StatsSectorSelection.index(value: 0, counts: counts) == 1)
        #expect(StatsSectorSelection.index(value: 1.99, counts: counts) == 1)
        #expect(StatsSectorSelection.index(value: 2, counts: counts) == 3)
        #expect(StatsSectorSelection.index(value: 5, counts: counts) == 4)
        for value in [-1.0, 6, .infinity, .nan] {
            #expect(StatsSectorSelection.index(value: value, counts: counts) == nil)
        }
        #expect(StatsSectorSelection.index(value: 0, counts: [0, 0]) == nil)
    }
}
