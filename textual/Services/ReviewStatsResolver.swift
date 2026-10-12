import Foundation

/// Per-field provenance prevents a community estimate from replacing a reader's
/// own assessment. Pass saved/explicitly submitted reviews here, never editor drafts.
enum ReviewStatsResolver {
    enum Source: String, Sendable { case personal, imported, community, catalog }
    struct Value<T: Equatable & Sendable>: Equatable, Sendable {
        let value: T
        let source: Source
    }

    static func pace(personal: ReaderReviewContent?, imported: String?, community: CommunityReviewSummary?) -> Value<ReaderReviewContent.Pace>? {
        if let value = personal?.pace { return .init(value: value, source: .personal) }
        if let value = imported.flatMap({ ReaderReviewContent.Pace(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }) {
            return .init(value: value, source: .imported)
        }
        guard let raw = winner(community?.pace, minimum: community?.minimumContributors ?? 5),
              let value = ReaderReviewContent.Pace(rawValue: raw) else { return nil }
        return .init(value: value, source: .community)
    }

    static func fiction(personal: ReaderReviewContent?, community: CommunityReviewSummary?, catalog: ReaderReviewContent.Fiction?) -> Value<ReaderReviewContent.Fiction>? {
        if let value = personal?.fiction { return .init(value: value, source: .personal) }
        if let raw = winner(community?.fiction, minimum: community?.minimumContributors ?? 5),
           let value = ReaderReviewContent.Fiction(rawValue: raw) { return .init(value: value, source: .community) }
        return catalog.map { .init(value: $0, source: .catalog) }
    }

    static func moods(personal: ReaderReviewContent?, imported: [String], community: CommunityReviewSummary?) -> Value<[String]>? {
        labels(personal: personal?.moods ?? [], imported: imported, distribution: community?.moods,
               minimum: community?.minimumContributors ?? 5, catalog: [])
    }
    static func genres(personal: ReaderReviewContent?, imported: [String] = [], community: CommunityReviewSummary?, catalog: [String]) -> Value<[String]>? {
        guard let result = labels(personal: personal?.genres ?? [], imported: imported, distribution: community?.genres,
                                  minimum: community?.minimumContributors ?? 5, catalog: catalog) else { return nil }
        // Match Archive/Stats labels, so review slugs and catalog subject names
        // cannot become separate buckets for the same genre.
        let values = result.value.map { $0 == "childrens" ? "Children’s" : $0.replacingOccurrences(of: "-", with: " ") }
        return .init(value: GenreTaxonomy.normalized(values, isOpenLibrary: false).sorted(), source: result.source)
    }

    private static func winner(_ distribution: CommunityReviewSummary.Distribution?, minimum: Int) -> String? {
        guard let distribution, distribution.contributors >= max(5, minimum) else { return nil }
        let values = distribution.counts.sorted { $0.value > $1.value }
        guard let top = values.first, top.value <= distribution.contributors,
              Double(top.value) / Double(distribution.contributors) >= 0.6,
              values.count < 2 || top.value > values[1].value else { return nil }
        return top.key
    }
    private static func labels(personal: [String], imported: [String], distribution: CommunityReviewSummary.Distribution?, minimum: Int, catalog: [String]) -> Value<[String]>? {
        func clean(_ values: [String]) -> [String] {
            Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })).sorted()
        }
        for (values, source) in [(personal, Source.personal), (imported, .imported)] {
            let values = clean(values)
            if !values.isEmpty { return .init(value: values, source: source) }
        }
        if let distribution, distribution.contributors >= max(5,minimum) {
            let values = distribution.counts.filter {
                $0.value >= 3 && $0.value <= distribution.contributors && Double($0.value) / Double(distribution.contributors) >= 0.4
            }.map(\.key).sorted()
            if !values.isEmpty { return .init(value: values, source: .community) }
        }
        let values = clean(catalog)
        return values.isEmpty ? nil : .init(value: values, source: .catalog)
    }
}
