import Foundation
import Testing
@testable import textual

struct ReviewStatsResolverTests {
    private func summary(_ json: String) throws -> CommunityReviewSummary {
        try JSONDecoder().decode(CommunityReviewSummary.self, from: Data(json.utf8))
    }
    @Test func personalAndImportedAssessmentsWinPerField() throws {
        let community = try summary(#"{"minimumContributors":5,"pace":{"contributors":5,"counts":{"fast":4,"slow":1}},"moods":{"contributors":5,"counts":{"dark":4,"hopeful":1}}}"#)
        var personal = ReaderReviewContent(); personal.pace = .medium
        #expect(ReviewStatsResolver.pace(personal: personal, imported: "slow", community: community)?.source == .personal)
        #expect(ReviewStatsResolver.pace(personal: nil, imported: " SLOW ", community: community)?.value == .slow)
        #expect(ReviewStatsResolver.pace(personal: nil, imported: nil, community: community)?.value == .fast)
        #expect(ReviewStatsResolver.moods(personal: personal, imported: [], community: community)?.value == ["dark"])
        #expect(ReviewStatsResolver.moods(personal: nil, imported: ["Hopeful"], community: community)?.source == .imported)
    }
    @Test func reviewSlugsUseTheSameGenreLabelsAsTheCatalog() {
        let genres = ReviewStatsResolver.genres(catalog: ["Science fiction", "LGBTQIA+"])
        #expect(genres?.value == ["LGBTQIA+", "Science fiction"])
        #expect(genres?.source == .catalog)
    }
    @Test func insufficientOrDividedCommunityDoesNotInventClassification() throws {
        let divided = try summary(#"{"minimumContributors":5,"pace":{"contributors":6,"counts":{"fast":3,"slow":3}}}"#)
        #expect(ReviewStatsResolver.pace(personal: nil, imported: nil, community: divided) == nil)
        let small = try summary(#"{"minimumContributors":5,"pace":{"contributors":4,"counts":{"fast":4}}}"#)
        #expect(ReviewStatsResolver.pace(personal: nil, imported: nil, community: small) == nil)
        #expect(ReviewStatsResolver.fiction(catalog: .fiction)?.source == .catalog)
        #expect(ReviewStatsResolver.genres(catalog: ["Fantasy"])?.value == ["Fantasy"])
    }

    @Test func catalogMoodTermsRetainEvidenceAndUseExistingVocabulary() {
        let cases: [(String, String)] = [
            ("FICTION / Fantasy / Dark Fantasy", "dark"), ("Fiction, thrillers, suspense", "tense"),
            ("Adventure stories", "adventurous"), ("Detective and mystery stories", "mysterious"),
            ("Philosophical fiction", "reflective"), ("Sentimental fiction", "emotional"),
            ("Self-Help / Motivational & Inspirational", "inspiring"), ("Reference / Dictionaries", "informative"),
            ("Humorous stories -- Juvenile fiction", "funny"), ("Tragedies", "sad"),
            ("Hopeful fiction", "hopeful"), ("Light-hearted fiction", "lighthearted")
        ]
        for (category, mood) in cases {
            let estimate = CatalogMoodEstimate(categories: [category, category])
            #expect(estimate.moods == [mood])
            #expect(estimate.evidence[mood] == [category])
        }
    }

    @Test func broadSubjectsAndWordsInsideSubjectsDoNotInventTone() {
        let estimate = CatalogMoodEstimate(categories: ["Fiction", "Nonfiction", "Biography", "Fantasy", "Romance",
            "Death", "Grief", "Mental health", "Horror -- History and criticism", "Comedy -- Study and teaching",
            "Dark matter", "Emotional intelligence", "Sadness", "Hope", "Self-help", "Women", "Adventure travel"])
        #expect(estimate.moods.isEmpty)
    }

    @Test func catalogMoodsAreLastResortAndNeverMixedIntoReaderAssessments() throws {
        var personal = ReaderReviewContent(); personal.moods = ["reflective"]
        let community = try summary(#"{"minimumContributors":5,"moods":{"contributors":5,"counts":{"funny":3}}}"#)
        let categories = ["Fiction / Horror", "Fiction / Thrillers / Suspense"]
        let own = ReviewStatsResolver.moods(personal: personal, imported: ["Hopeful"], community: community, catalogCategories: categories)
        #expect(own?.source == .personal && own?.value == ["reflective"])
        let imported = ReviewStatsResolver.moods(personal: nil, imported: ["Hopeful"], community: community, catalogCategories: categories)
        #expect(imported?.source == .imported && imported?.value == ["hopeful"])
        let shared = ReviewStatsResolver.moods(personal: nil, imported: [], community: community, catalogCategories: categories)
        #expect(shared?.source == .community && shared?.value == ["funny"])
        let estimated = ReviewStatsResolver.moods(personal: nil, imported: [" "], community: nil, catalogCategories: categories)
        #expect(estimated?.source == .catalog && estimated?.value == ["dark", "tense"])
        #expect(ReviewStatsResolver.moods(personal: nil, imported: [], community: nil, catalogCategories: ["Fiction"]) == nil)
    }

    @Test func explicitPaceWinsOverGenreAndConflictingOrNegatedCluesStayCautious() {
        func estimate(_ text: String, genres: Set<String> = []) -> CatalogPaceEstimate {
            .init(categories: [], context: [text], genres: genres)
        }
        #expect(estimate("A fast-paced novel.", genres: ["Literary"]).value == .fast)
        #expect(estimate("An unhurried pace", genres: ["Thriller"]).value == .slow)
        #expect(estimate("Moderately paced").value == .medium)
        let mixed = estimate("A fast-paced beginning and a slow-paced ending")
        #expect(mixed.value == .medium && mixed.reason.contains("differ"))
        #expect(estimate("Not a fast-paced book").value == .medium)
        #expect(estimate("Slow-burning romance").value == .medium)
        #expect(estimate("Fast cars and slow trains").value == .medium)
        #expect(estimate("", genres: ["Thriller"]).value == .fast)
        #expect(estimate("", genres: ["Poetry"]).value == .slow)
        #expect(estimate("").reason.contains("default"))
    }

    @Test func recordedAndCommunityPaceOverrideCatalogEstimate() throws {
        let estimate = CatalogPaceEstimate(categories: [], context: ["Fast-paced"], genres: [])
        var personal = ReaderReviewContent(); personal.pace = .slow
        let community = try summary(#"{"minimumContributors":5,"pace":{"contributors":5,"counts":{"medium":4}}}"#)
        #expect(ReviewStatsResolver.pace(personal: personal, imported: "medium", community: community, estimate: estimate)?.source == .personal)
        #expect(ReviewStatsResolver.pace(personal: nil, imported: " SLOW ", community: community, estimate: estimate)?.value == .slow)
        #expect(ReviewStatsResolver.pace(personal: nil, imported: nil, community: community, estimate: estimate)?.source == .community)
        let result = ReviewStatsResolver.pace(personal: nil, imported: "unknown", community: nil, estimate: estimate)
        #expect(result?.source == .estimated && result?.value == .fast)
    }

    @Test func pageEstimatesUseVerifiedEditionLengthsThenExplicitlyLabeledDefaults() {
        func estimate(_ counts: [Int], _ categories: [String] = [], _ genres: Set<String> = []) -> CatalogPageEstimate {
            .init(workPageCounts: counts, categories: categories, kind: .fiction, genres: genres)
        }
        #expect(estimate([0, -10, 288, 304, 320, 99_999]).value == 304)
        #expect(estimate([280, 320]).value == 300)
        #expect(estimate([304]).reason.contains("API-verified"))
        #expect(estimate([], ["Picture books"]).value == 32)
        #expect(estimate([], ["Novella"]).value == 120)
        #expect(estimate([], [], ["Graphic novels"]).value == 200)
        #expect(estimate([]).value == 320 && estimate([]).reason.hasPrefix("Low-confidence"))
    }

}
