import Foundation

/// Per-field provenance prevents a community estimate from replacing a reader's
/// own assessment. Pass saved/explicitly submitted reviews here, never editor drafts.
enum ReviewStatsResolver {
    enum Source: String, Sendable { case personal, imported, community, catalog, estimated }
    struct Value<T: Equatable & Sendable>: Equatable, Sendable {
        let value: T
        let source: Source
    }

    static func pace(personal: ReaderReviewContent?, imported: String?, community: CommunityReviewSummary?, estimate: CatalogPaceEstimate? = nil) -> Value<ReaderReviewContent.Pace>? {
        if let value = personal?.pace { return .init(value: value, source: .personal) }
        if let value = imported.flatMap({ ReaderReviewContent.Pace(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }) {
            return .init(value: value, source: .imported)
        }
        if let raw = winner(community?.pace, minimum: community?.minimumContributors ?? 5),
           let value = ReaderReviewContent.Pace(rawValue: raw) { return .init(value: value, source: .community) }
        return estimate.map { .init(value: $0.value, source: .estimated) }
    }

    // Book classification belongs to verified public catalogs, never review votes.
    static func fiction(catalog: BookFictionKind?) -> Value<BookFictionKind>? {
        catalog.map { .init(value: $0, source: .catalog) }
    }

    static func moods(personal: ReaderReviewContent?, imported: [String], community: CommunityReviewSummary?, catalogCategories: [String] = []) -> Value<[String]>? {
        labels(personal: personal?.moods ?? [], imported: imported, distribution: community?.moods,
               minimum: community?.minimumContributors ?? 5, catalog: CatalogMoodEstimate(categories: catalogCategories).moods)
    }
    static func genres(catalog: [String]) -> Value<[String]>? {
        let values = GenreTaxonomy.normalized(catalog, isOpenLibrary: false).sorted()
        return values.isEmpty ? nil : .init(value: values, source: .catalog)
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

/// Tone estimates use explicit catalog terms, never titles, descriptions, or broad
/// genre stereotypes. Retain the original categories so every estimate is explainable.
struct CatalogMoodEstimate: Equatable, Sendable {
    let evidence: [String: [String]]
    var moods: [String] { evidence.keys.sorted() }

    init(categories: [String]) {
        var matches: [String: Set<String>] = [:]
        for category in categories {
            let normalized = Self.key(category)
            // A book about a literary form does not necessarily share that tone.
            guard !["criticism", "history", "study and teaching", "psychology"].contains(where: {
                (" " + normalized + " ").contains(" " + $0 + " ")
            }) else { continue }
            let parts = category.replacingOccurrences(of: "--", with: "/")
                .components(separatedBy: CharacterSet(charactersIn: "/,")).map(Self.key)
            let terms = Set(parts + [normalized])
            for (mood, aliases) in Self.rules where !terms.isDisjoint(with: aliases) {
                matches[mood, default: []].insert(category)
            }
        }
        evidence = matches.mapValues { $0.sorted() }
    }

    private static func key(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "&", with: " and ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // Existing mood vocabulary. Less common tones require equally explicit labels.
    private static let rules: [String: Set<String>] = [
        "dark": ["horror", "horror fiction", "horror tales", "dark fantasy", "dark fantasy fiction", "gothic fiction", "gothic horror"],
        "tense": ["thriller", "thrillers", "thriller fiction", "thrillers fiction", "suspense", "suspense fiction", "suspenseful fiction"],
        "adventurous": ["action and adventure", "adventure", "adventure fiction", "adventure stories", "action and adventure fiction"],
        "mysterious": ["mystery", "mysteries", "mystery fiction", "mystery and detective", "detective and mystery stories", "detective and mystery fiction"],
        "reflective": ["reflective", "reflective fiction", "contemplative fiction", "meditative fiction", "philosophical fiction"],
        "emotional": ["emotional", "emotional fiction", "poignant fiction", "sentimental fiction"],
        "inspiring": ["inspiring", "inspirational", "inspirational fiction", "inspirational literature", "motivational", "motivational and inspirational", "inspiration and personal growth"],
        "informative": ["reference", "reference works", "handbooks manuals etc", "study aids", "textbooks", "encyclopedias", "dictionaries", "instructional", "informative"],
        "funny": ["humor", "humour", "humorous", "humorous fiction", "humorous stories", "comedy", "comedies", "comic fiction", "satire", "satirical fiction", "jokes and riddles"],
        "sad": ["sad", "sad fiction", "sad stories", "tragic fiction", "tragedy", "tragedies"],
        "hopeful": ["hopeful", "hopeful fiction", "optimistic fiction"],
        "lighthearted": ["lighthearted", "light hearted", "lighthearted fiction", "light hearted fiction", "light comedy"]
    ]
}

/// Narrative pace, not reading speed. Length and reading dates are not pace evidence.
struct CatalogPaceEstimate: Sendable {
    let value: ReaderReviewContent.Pace
    let reason: String

    init(categories: [String], context: [String], genres: Set<String>) {
        let texts = (categories + context).map { text in
            text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        }
        func mentions(_ phrase: String) -> Bool {
            let phrase = phrase.split(separator: " ").map(String.init)
            return texts.contains { words in
                guard words.count >= phrase.count else { return false }
                return (0...(words.count - phrase.count)).contains { index in
                    let preceding = words[max(0, index - 3)..<index]
                    return Array(words[index..<(index + phrase.count)]) == phrase
                        && !preceding.contains(where: { ["not", "never", "isn", "isnt", "without"].contains($0) })
                }
            }
        }
        let explicit: [(ReaderReviewContent.Pace, [String])] = [
            (.fast, ["fast paced", "fast moving", "briskly paced", "rapid paced", "breakneck pace"]),
            (.slow, ["slow paced", "slowly paced", "leisurely paced", "unhurried pace", "deliberately paced"]),
            (.medium, ["moderately paced", "evenly paced", "steady pace", "steadily paced", "medium paced"])
        ]
        let matches = explicit.compactMap { pace, terms in terms.first(where: mentions).map { (pace, $0) } }
        if matches.count == 1, let match = matches.first {
            value = match.0; reason = "Estimated from catalog description: “\(match.1)”"; return
        }
        if matches.count > 1 {
            value = .medium; reason = "Low-confidence Medium estimate: catalog pace descriptions differ"; return
        }
        let fast = ["page turner", "action packed", "propulsive", "relentless suspense"].first(where: mentions)
        let slow = ["meditative", "contemplative", "unhurried"].first(where: mentions)
        if let term = fast, slow == nil {
            value = .fast; reason = "Low-confidence pace estimate from catalog: “\(term)”"; return
        }
        if let term = slow, fast == nil {
            value = .slow; reason = "Low-confidence pace estimate from catalog: “\(term)”"; return
        }
        if fast != nil && slow != nil {
            value = .medium; reason = "Low-confidence Medium estimate: mixed pacing clues"; return
        }
        let fastGenres: Set<String> = ["Thriller", "Adventure"]
        let slowGenres: Set<String> = ["Literary", "Poetry", "Philosophy"]
        let likelyFast = !genres.isDisjoint(with: fastGenres)
        let likelySlow = !genres.isDisjoint(with: slowGenres)
        if likelyFast != likelySlow {
            value = likelyFast ? .fast : .slow
            reason = "Low-confidence pace estimate from genre; individual books vary"
        } else {
            value = .medium; reason = "Low-confidence Medium default: limited or mixed pace context"
        }
    }
}

/// Another edition's length is an estimate, never the saved edition's exact count.
struct CatalogPageEstimate: Sendable {
    let value: Int
    let reason: String

    init(workPageCounts: [Int], categories: [String], kind: BookFictionKind, genres: Set<String>) {
        let counts = workPageCounts.filter { (1...20_000).contains($0) }.sorted()
        if !counts.isEmpty {
            let middle = counts.count / 2
            value = counts.count.isMultiple(of: 2) ? (counts[middle - 1] + counts[middle]) / 2 : counts[middle]
            reason = "Estimated from API-verified editions of the same book"; return
        }
        let terms = categories.map { " " + $0.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ") + " " }
        func has(_ phrase: String) -> Bool { terms.contains { $0.contains(" " + phrase + " ") } }
        if has("picture book") || has("picture books") {
            value = 32; reason = "Low-confidence book-type default: picture book"
        } else if has("novella") || has("novellas") {
            value = 120; reason = "Low-confidence book-type default: novella"
        } else if genres.contains("Poetry") {
            value = 120; reason = "Low-confidence book-type default: poetry"
        } else if genres.contains("Graphic novels") {
            value = 200; reason = "Low-confidence book-type default: graphic novel"
        } else if genres.contains("Middle grade") {
            value = 240; reason = "Low-confidence book-type default: middle grade"
        } else {
            value = kind == .fiction ? 320 : 280
            reason = "Low-confidence length default: limited catalog page information"
        }
    }
}
