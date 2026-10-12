import Foundation
import Testing
@testable import textual

struct BookDetailPresentationTests {
    @Test func removesEditionAppendicesAfterInlineAndBlockDividers() {
        for divider in [" ---------- ", "\n---\n", "\n- - -\n", "\n———\n", "<hr />"] {
            #expect(BookDetailPresentation.description("A novel about truth and politics." + divider + "Also contained in: [Novels](https://openlibrary.org/works/OL1W)") == "A novel about truth and politics.")
        }
        #expect(BookDetailPresentation.description("A thought-provoking novel — set in a post-war world.") == "A thought-provoking novel — set in a post-war world.")
        #expect(BookDetailPresentation.description("<p>A <b>novel</b>.</p><hr>Appendix") == "<p>A <b>novel</b>.</p>")
        #expect(BookDetailPresentation.description(nil) == nil)
        #expect(BookDetailPresentation.description("  ") == nil)
        #expect(BookDetailPresentation.description("---------- Appendix") == nil)
        #expect(BookDetailPresentation.description("<p>----------</p>Appendix") == nil)
    }

    @Test func limitsNoisySubjectsToFiveUsefulDistinctCategories() {
        let subjects = ["Chinese Philosophy", "Chinese language materials", "Peace", "Tao", "Taoism", "Ouvrages avant 1800", "Taoïsme", "Religion", "Asian Philosophy", "Philosophy", "New Age", "General", "Religion / Eastern", "Mind, body, spirit: disciplines & techniques", "Body, Mind & Spirit", "Religion - World Religions", "Spiritualism - General", "BG-JUVENILE PROP - BG-JUVY ACTIVITY", "Body, Mind & Spirit / Spiritualism", "Religion - Commentaries / Reference", "Reference", "China", "Non-Western philosophy"]
        let categories = BookDetailPresentation.categories(subjects, title: "Tao Te Ching", description: "Chinese philosophy on the Tao and peace.")
        #expect(categories.count == 5)
        #expect(categories.first == "Chinese Philosophy")
        #expect(categories.contains("Taoism"))
        #expect(categories.contains("Peace"))
        #expect(!categories.contains("Philosophy"))
        #expect(!categories.contains("Tao") && !categories.contains("Taoïsme"))
        #expect(!categories.contains { $0.contains("BG-") || $0.contains("language materials") || $0 == "General" })
        #expect(categories == BookDetailPresentation.categories(subjects, title: "Tao Te Ching", description: "Chinese philosophy on the Tao and peace."))
    }

    @Test func ranksSynopsisEvidenceAheadOfProviderOrderAndIgnoresAppendix() {
        let categories = BookDetailPresentation.categories(
            ["History", "Religion", "Travel", "Nature", "Business", "Dystopian", "Politics"],
            title: "Nineteen Eighty-Four", description: "A dystopian novel about politics and truth. ---------- Travel history business")
        #expect(Array(categories.prefix(2)) == ["Dystopian", "Politics"])
        #expect(categories.count == 5)
    }

    @Test func collapsesCaseHierarchyAndPunctuationWithoutPaddingToFive() {
        #expect(BookDetailPresentation.categories(["  Fantasy ", "FANTASY", "Fiction / Fantasy / General", "General"], title: nil, description: nil) == ["Fantasy"])
        #expect(BookDetailPresentation.categories(["Sci-fi", "Science Fiction"], title: nil, description: nil) == ["Science fiction"])
        #expect(BookDetailPresentation.categories([], title: nil, description: nil).isEmpty)
        #expect(BookDetailPresentation.categories(["General", "Reference", "Fiction / General"], title: nil, description: nil).isEmpty)
    }
}

@MainActor
struct BookDetailDisplayIntegrationTests {
    @Test func cleansBothFreshAndPreviouslyCachedMetadataWithoutRewritingIt() throws {
        let data = try JSONSerialization.data(withJSONObject: ["id": "openlibrary:OL1W", "volumeInfo": [
            "title": "A dystopian book", "description": "Politics and truth. ---------- Also contained in: [Collection](https://openlibrary.org/works/OL2W)",
            "categories": ["General", "Reference", "Dystopian", "Politics", "Science fiction", "Fiction", "Literary", "Classics", "History"]
        ]])
        let item = try JSONDecoder().decode(BookCatalogService.BookItem.self, from: data)
        let model = BookDetailViewModel()
        let book = Book(title: "A dystopian book", author: "Author", isbn: "fixture")
        book.cachedCatalogMetadata = data
        for volume in [item, model.savedVolume(book: book)] {
            #expect(model.description(from: volume) == "Politics and truth.")
            #expect(model.categories(from: volume).count == 5)
            #expect(!model.categories(from: volume).contains("General"))
        }
        #expect(book.cachedCatalogMetadata == data)
    }
}
