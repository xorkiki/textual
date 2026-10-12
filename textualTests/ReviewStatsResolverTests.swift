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
        var personal = ReaderReviewContent(); personal.genres = ["science-fiction", "lgbtqia"]
        let genres = ReviewStatsResolver.genres(personal: personal, community: nil, catalog: [])
        #expect(genres?.value == ["LGBTQIA+", "Science fiction"])
        #expect(genres?.source == .personal)
    }
    @Test func insufficientOrDividedCommunityDoesNotInventClassification() throws {
        let divided = try summary(#"{"minimumContributors":5,"pace":{"contributors":6,"counts":{"fast":3,"slow":3}}}"#)
        #expect(ReviewStatsResolver.pace(personal: nil, imported: nil, community: divided) == nil)
        let small = try summary(#"{"minimumContributors":5,"pace":{"contributors":4,"counts":{"fast":4}}}"#)
        #expect(ReviewStatsResolver.pace(personal: nil, imported: nil, community: small) == nil)
        #expect(ReviewStatsResolver.fiction(personal: nil, community: small, catalog: .fiction)?.source == .catalog)
        #expect(ReviewStatsResolver.genres(personal: nil, community: small, catalog: ["Fantasy"])?.value == ["Fantasy"])
    }
}
