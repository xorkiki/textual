import Foundation
import Testing
@testable import textual

struct GenreTaxonomyTests {
    @Test func queerSubjectsRollUpWithoutLosingOtherGenres() {
        let cases: [(String, Set<String>)] = [
            ("Gay fiction", ["LGBTQIA+"]),
            ("Lesbian romance", ["LGBTQIA+", "Romance"]),
            ("Bisexual", ["LGBTQIA+"]),
            ("FICTION / Romance / LGBTQ+ / Bisexual", ["Romance", "LGBTQIA+"]),
            ("Young adult fiction -- Transgender people", ["Young adult", "LGBTQIA+"]),
            ("Non-binary characters in fantasy fiction", ["LGBTQIA+", "Fantasy"]),
            ("Sapphic historical romance", ["LGBTQIA+", "Historical", "Romance"]),
            ("Genderqueer poetry", ["LGBTQIA+", "Poetry"]),
            ("Asexuality", ["LGBTQIA+"]),
            ("Intersex people", ["LGBTQIA+"]),
            ("Same-sex relationships", ["LGBTQIA+"])
        ]
        for (subject, expected) in cases {
            #expect(GenreTaxonomy.normalized([subject], isOpenLibrary: true) == expected, "\(subject)")
            #expect(GenreTaxonomy.normalized([subject], isOpenLibrary: false) == expected, "\(subject)")
        }
    }

    @Test func narrowerSubjectsAndSpellingVariantsReachEveryExistingFamily() {
        let cases: [(String, String)] = [
            ("Urban fantasy novels", "Fantasy"), ("Romantic suspense", "Romance"),
            ("Personal narratives", "Memoir"), ("Biographical writings", "Biography"),
            ("Teen fiction", "Young adult"), ("Middle-grade novels", "Middle grade"),
            ("Historical mysteries", "Historical"), ("Literary novels", "Literary"),
            ("Psychological thrillers", "Thriller"), ("Cozy mysteries", "Mystery"),
            ("Noir fiction", "Crime"), ("True-crime accounts", "True crime"),
            ("Personal development", "Self help"), ("Lesbian romance", "LGBTQIA+"),
            ("Feminist fiction", "Feminism"), ("Cyberpunk", "Science fiction"),
            ("Collected poems", "Poetry"), ("Post-apocalyptic fiction", "Dystopian"),
            ("Contemporary romance", "Contemporary"), ("Ghost stories", "Horror"),
            ("Action & adventure", "Adventure"), ("Fine arts", "Art"),
            ("Personal essays", "Essays"), ("Classic literature", "Classics"),
            ("Health & fitness", "Health"), ("Political science", "Politics"),
            ("Ethics", "Philosophy"), ("Psychotherapy", "Psychology"),
            ("World history", "History"), ("Entrepreneurship", "Business"),
            ("Physics", "Science"), ("Theology", "Religion"),
            ("Travelogues", "Travel"), ("Cookery", "Cooking"),
            ("Humour", "Humor"), ("Manga", "Graphic novels"),
            ("Short fiction", "Short stories"), ("Dramatic works", "Drama"),
            ("Songwriting", "Music"), ("Athletics", "Sports"),
            ("Wildlife conservation", "Nature"), ("Computer programming", "Technology"),
            ("Pedagogy", "Education"), ("Children’s stories", "Children’s"),
            ("Erotic fiction", "Erotica"), ("Western fiction", "Western")
        ]
        for (subject, expected) in cases {
            #expect(GenreTaxonomy.normalized([subject], isOpenLibrary: true).contains(expected), "\(subject) → \(expected)")
        }
    }

    @Test func boundariesAndContextPreventFalseMatches() {
        #expect(GenreTaxonomy.normalized(["Science fiction"], isOpenLibrary: true) == ["Science fiction"])
        #expect(GenreTaxonomy.normalized(["Political science"], isOpenLibrary: true) == ["Politics"])
        #expect(GenreTaxonomy.normalized(["Computer science"], isOpenLibrary: true) == ["Technology"])
        #expect(GenreTaxonomy.normalized(["Psychological thrillers"], isOpenLibrary: true) == ["Thriller"])
        #expect(GenreTaxonomy.normalized(["True crime"], isOpenLibrary: true) == ["True crime"])
        #expect(GenreTaxonomy.normalized(["Natural history"], isOpenLibrary: true) == ["Nature"])
        #expect(GenreTaxonomy.normalized(["Asexual reproduction", "Bisexual reproduction"], isOpenLibrary: true).isEmpty)
        #expect(GenreTaxonomy.normalized(["Gaylord", "Romanticism", "Romance languages", "New York", "Arthur Smith"], isOpenLibrary: true).isEmpty)
        #expect(GenreTaxonomy.normalized(["Juvenile fiction"], isOpenLibrary: true) == ["Children’s"])
        #expect(GenreTaxonomy.normalized(["Fiction / General"], isOpenLibrary: false).isEmpty)
        #expect(GenreTaxonomy.normalized([], isOpenLibrary: false).isEmpty)
    }

    @Test func punctuationHierarchyAndDuplicateLabelsStayConsistent() {
        let result = GenreTaxonomy.normalized(["  SCI-FI ", "Science Fiction", "Fiction / Science Fiction / General"], isOpenLibrary: true)
        #expect(result == ["Science fiction"])
        #expect(GenreTaxonomy.normalized(["FICTION / Romance / Historical"], isOpenLibrary: false) == ["Romance", "Historical"])
        #expect(GenreTaxonomy.normalized(["Romantasy"], isOpenLibrary: false) == ["Romance", "Fantasy"])
        #expect(GenreTaxonomy.normalized(["Fiction / Solarpunk"], isOpenLibrary: false) == ["Solarpunk"])
        #expect(GenreTaxonomy.normalized(["Fiction / Science Fiction", "Science / Physics"], isOpenLibrary: true) == ["Science fiction", "Science"])
    }
}

@MainActor
struct SharedGenreLookupTests {
    @Test func allPagesUseNewEvidenceForAnyAccountAndKeepTheReadingDataIntact() throws {
        for title in ["Reader one’s book", "Reader two’s book"] {
            let book = try fixture(title)
            let original = book.storyGraphData
            let oldMetadata = book.cachedCatalogMetadata
            let expected: Set<String> = ["LGBTQIA+", "Romance"]
            #expect(StatsMetadataCache.genres(book) == expected)
            let archive = ArchiveFilterCatalog(books: [book])
            #expect(Set(archive.options.genres) == expected)
            #expect(archive.books(matching: .init(genre: "LGBTQIA+")).map(\.id) == [book.id])
            #expect(archive.books(matching: .init(genre: "Romance")).map(\.id) == [book.id])
            #expect(archive.books(matching: .init(status: .tbr, genre: "LGBTQIA+")).isEmpty)
            let stats = UserReadingStats(books: [book], filter: .init(status: "read", year: nil))
            #expect(Set(stats.genres.map(\.name)) == expected)
            #expect(ReaderPersonality.evidence([book]).first?.genres == expected)
            #expect(book.storyGraphData == original)
            #expect(book.cachedCatalogMetadata == oldMetadata)
        }
    }

    @Test func missingOrGenericNewEvidenceFallsBackToSavedSubjects() throws {
        let book = try fixture("Fallback")
        book.cachedStatsClassification = Data("invalid".utf8)
        #expect(StatsMetadataCache.genres(book) == ["Fantasy"])
        book.cachedStatsClassification = try JSONEncoder().encode(BookCatalogService.ClassificationEvidence(categories: ["Fiction"], source: "google"))
        #expect(StatsMetadataCache.genres(book) == ["Fantasy"])
    }

    private func fixture(_ title: String) throws -> Book {
        let book = Book(title: title, author: "Writer", isbn: "fixture")
        book.storyGraphData = try JSONEncoder().encode(StoryGraphReadingData(sourceKey: title, status: "read",
            dateAdded: nil, lastDateRead: nil, periods: [], readCount: 1, rating: nil, format: "",
            moods: [], pace: "", tags: [], owned: nil, originalFields: [:]))
        book.cachedCatalogMetadata = try JSONSerialization.data(withJSONObject: ["id": "old", "volumeInfo": ["categories": ["Fantasy"]]])
        book.cachedStatsClassification = try JSONEncoder().encode(BookCatalogService.ClassificationEvidence(categories: ["Lesbian romance"], source: "google"))
        return book
    }
}
