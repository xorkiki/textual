import Foundation
import Testing
@testable import textual

@MainActor
struct ArchiveFilterTests {
    @Test func combinesStatusGenreMoodAndPaceWithoutChangingAvailableChoices() throws {
        let fantasy = try book("First", status: "read", categories: ["Fiction / Fantasy / General"], moods: ["dark", "reflective"], pace: "fast")
        let romance = try book("Second", status: "read", categories: ["Fiction / Romance"], moods: ["dark"], pace: "slow")
        let tbr = try book("Third", status: "to-read", categories: ["Fiction / Fantasy"], moods: ["funny"], pace: "medium")
        let dnf = try book("Fourth", status: "did-not-finish", categories: ["Poetry"], moods: ["sad"], pace: "slow")
        let catalog = ArchiveFilterCatalog(books: [fantasy, romance, tbr, dnf])
        #expect(catalog.options.genres == ["Fantasy", "Poetry", "Romance"])
        #expect(catalog.options.moods == ["Dark", "Funny", "Reflective", "Sad"])
        #expect(catalog.options.paces == ["Fast", "Medium", "Slow"])
        var filter = ArchiveFilter()
        #expect(catalog.books(matching: filter).map(\.id) == [fantasy.id, romance.id])
        filter.mood = "Dark"
        filter.genre = "Fantasy"
        filter.pace = "Fast"
        #expect(catalog.books(matching: filter).map(\.id) == [fantasy.id])
        filter.pace = "Slow"
        #expect(catalog.books(matching: filter).isEmpty)
        filter = ArchiveFilter(status: .tbr)
        #expect(catalog.books(matching: filter).map(\.id) == [tbr.id])
        filter.status = .dnf
        #expect(catalog.books(matching: filter).map(\.id) == [dnf.id])
    }

    @Test func derivesDeduplicatedOptionsFromLiveBooksIncludingUncommonValues() throws {
        let first = try book("First", status: "read", categories: ["fantasy fiction", "New York"], moods: [" DARK ", "dark", "", "hopeful"], pace: " FAST ", catalogID: "openlibrary:/works/one")
        let second = try book("Second", status: "to-read", categories: ["Fiction / Cyberpunk"], moods: [" Hopeful "], pace: "variable")
        let removed = try book("Removed", status: "read", categories: ["Poetry"], moods: ["Sad"], pace: "Slow")
        removed.isRemovedFromLibrary = true
        let catalog = ArchiveFilterCatalog(books: [first, second, removed])
        #expect(catalog.options.genres == ["Fantasy", "Science fiction"])
        #expect(catalog.options.moods == ["Dark", "Hopeful"])
        #expect(catalog.options.paces == ["Fast", "Variable"])
        #expect(catalog.books(matching: .init()).map(\.id) == [first.id])
    }

    @Test func missingMetadataDoesNotInventGenresAndNewSavesRemainReachableInTBR() throws {
        let saved = Book(title: "New", author: "Author", isbn: "new")
        saved.cachedCatalogMetadata = Data("invalid".utf8)
        let read = try book("Read", status: "read", categories: [], moods: [], pace: "")
        let catalog = ArchiveFilterCatalog(books: [saved, read])
        #expect(catalog.options == .init(genres: [], moods: [], paces: []))
        #expect(catalog.books(matching: .init()).map(\.id) == [read.id])
        #expect(catalog.books(matching: .init(status: .tbr)).map(\.id) == [saved.id])
        #expect(catalog.books(matching: .init(genre: "Fantasy")).isEmpty)
        var selection = ArchiveFilter(status: .dnf, genre: "Fantasy", mood: "Dark", pace: "Fast")
        selection.reconcile(with: .init(genres: [], moods: ["Dark"], paces: []))
        #expect(selection == ArchiveFilter(status: .dnf, mood: "Dark"))
    }

    private func book(_ title: String, status: String, categories: [String], moods: [String], pace: String,
                      catalogID: String = "google-book") throws -> Book {
        let book = Book(title: title, author: "Author", isbn: title)
        book.storyGraphData = try JSONEncoder().encode(StoryGraphReadingData(sourceKey: title, status: status,
            dateAdded: nil, lastDateRead: nil, periods: [], readCount: nil, rating: nil, format: "",
            moods: moods, pace: pace, tags: [], owned: nil, originalFields: [:]))
        book.cachedCatalogMetadata = try JSONSerialization.data(withJSONObject: [
            "id": catalogID, "volumeInfo": ["categories": categories]
        ])
        return book
    }
}
