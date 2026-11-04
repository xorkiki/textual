import Foundation

/// One archive book reduced to the taste signals ranking needs. Values only, so
/// ranking runs off the main actor and never touches SwiftData models.
struct DiscoveryTasteBook: Sendable, Equatable {
    var catalogID: String?
    var title: String
    var author: String
    var isbns: [String] = []
    var genres: Set<String> = []
    /// Existing reading-data values: read, currently-reading, to-read, did-not-finish.
    var status: String?
    /// Stars, 0...5 (native review rating, else imported rating).
    var rating: Double?
    /// Position on the profile shelf; the first five are the reader's top five.
    var favoriteRank: Int?
}

/// A candidate drawn from cached discovery collections or favorite-author lookups.
struct DiscoveryCandidate: Sendable {
    let item: DiscoverItem
    let genres: Set<String>
    let collections: Set<String>

    init(item: DiscoverItem, collections: Set<String>, genres: Set<String>? = nil) {
        self.item = item
        self.collections = collections
        // Google categories and Open Library subjects follow the app-wide taxonomy rules.
        self.genres = genres ?? GenreTaxonomy.normalized(item.subjects, isOpenLibrary: item.catalogID.hasPrefix("openlibrary:")
                                           || item.facet != nil)
    }
}

struct DiscoveryRecommendation: Sendable {
    let item: DiscoverItem
    let score: Double
    let personal: Bool
    /// Structured, internal reasons ("author:…", "genre:…", "trending", "new", "explore").
    let reasons: [String]
}

/// Deterministic, metadata-based ranking for For You. No network, AI, or community
/// activity: it works from the reader's own archive and the cached candidate pools,
/// and degrades to a diverse editorial mix for an empty archive.
enum DiscoveryRecommender {
    static let limit = 300
    /// Roughly 70% personal / 30% exploratory once the archive carries enough signal.
    static let maximumPersonalShare = 0.7
    static let childrensGenres: Set<String> = ["Children’s", "Middle grade"]

    struct Profile: Sendable {
        var authors: [String: Double] = [:]
        var genres: [String: Double] = [:]
        /// Sum of positive evidence; drives the cold-start → personalized transition.
        var strength: Double = 0
        var archivedCatalogIDs: Set<String> = []
        var archivedISBNs: Set<String> = []
        var archivedWorks: Set<String> = []

        var genreNorm: Double { sqrt(genres.values.reduce(0) { $0 + $1 * $1 }) }
        var likesChildrens: Bool { childrensGenres.contains { (genres[$0] ?? 0) > 0 } }

        func isArchived(_ item: DiscoverItem) -> Bool {
            if archivedCatalogIDs.contains(item.catalogID) { return true }
            if item.isbns.contains(where: { StoryGraphImporter.normalizedISBN($0).map(archivedISBNs.contains) == true }) { return true }
            return DiscoveryIdentity.workKey(title: item.title, author: item.author).map(archivedWorks.contains) == true
        }
    }

    /// Signal weights. Favorites and five-star ratings dominate; DNF and low ratings
    /// are cautious negatives; TBR is a light hint.
    static func weight(_ book: DiscoveryTasteBook) -> Double {
        var weight = 0.0
        if let rank = book.favoriteRank { weight += rank < 5 ? 5 : 3 }
        if let rating = book.rating {
            switch rating {
            case 4.75...: weight += 4
            case 4..<4.75: weight += 2.5
            case 3..<4: weight += 0.75
            case ...2.5: weight -= 2.5
            default: break
            }
        } else {
            switch book.status {
            case "read": weight += 1
            case "currently-reading": weight += 1.25
            case "to-read": weight += 0.4
            case "did-not-finish": weight -= 1.5
            default: break
            }
        }
        return weight
    }

    static func profile(_ books: [DiscoveryTasteBook]) -> Profile {
        var profile = Profile()
        for book in books {
            if Task.isCancelled { return profile }
            if let id = book.catalogID, !id.isEmpty { profile.archivedCatalogIDs.insert(id) }
            for isbn in book.isbns { if let value = StoryGraphImporter.normalizedISBN(isbn) { profile.archivedISBNs.insert(value) } }
            if let work = DiscoveryIdentity.workKey(title: book.title, author: book.author) { profile.archivedWorks.insert(work) }
            let w = weight(book)
            guard w != 0 else { continue }
            profile.strength += max(0, w)
            let author = DiscoveryIdentity.primaryAuthorKey(book.author)
            if !author.isEmpty, author != "unknown author" { profile.authors[author, default: 0] += w }
            let share = book.genres.isEmpty ? 0 : w / sqrt(Double(book.genres.count))
            for genre in book.genres { profile.genres[genre, default: 0] += share }
        }
        return profile
    }

    static func personalShare(strength: Double) -> Double {
        maximumPersonalShare * min(1, max(0, strength) / 25)
    }

    struct Scored: Sendable {
        let candidate: DiscoveryCandidate
        let personal: Double
        let prior: Double
        let reasons: [String]
    }

    static func score(_ candidate: DiscoveryCandidate, profile: Profile) -> Scored {
        var reasons: [String] = []
        let authorKey = DiscoveryIdentity.primaryAuthorKey(candidate.item.author)
        let author = min(6, max(-6, profile.authors[authorKey] ?? 0))
        if author > 0 { reasons.append("author:\(candidate.item.author)") }
        var genre = 0.0
        let norm = profile.genreNorm
        if norm > 0, !candidate.genres.isEmpty {
            genre = candidate.genres.reduce(0) { $0 + (profile.genres[$1] ?? 0) } / (sqrt(Double(candidate.genres.count)) * norm)
            for match in candidate.genres.filter({ (profile.genres[$0] ?? 0) > 0 }).sorted() { reasons.append("genre:\(match)") }
        }
        var prior = min(1, log10(1 + Double(max(0, candidate.item.popularity))) / 4) * 0.6
        if candidate.collections.contains(DiscoveryCollection.trending.rawValue) { prior += 0.4; reasons.append("trending") }
        if candidate.collections.contains(DiscoveryCollection.newReleases.rawValue) { prior += 0.25; reasons.append("new") }
        if candidate.collections.contains(DiscoveryCollection.explore.rawValue) { reasons.append("explore") }
        return Scored(candidate: candidate, personal: 0.9 * author + 3 * genre, prior: prior, reasons: reasons)
    }

    /// Ranks candidates for one reader. Same inputs and seed always give the same list.
    static func recommend(books: [DiscoveryTasteBook], candidates: [DiscoveryCandidate],
                          seed: UInt64, limit: Int = limit) -> [DiscoveryRecommendation] {
        let profile = profile(books)
        var seen = Set<String>()
        var seenWorks = Set<String>()
        let scored = candidates.compactMap { candidate -> Scored? in
            guard !Task.isCancelled else { return nil }
            let item = candidate.item
            guard seen.insert(item.catalogID).inserted, !profile.isArchived(item) else { return nil }
            if let work = DiscoveryIdentity.workKey(title: item.title, author: item.author),
               !seenWorks.insert(work).inserted { return nil }
            if !profile.likesChildrens, !candidate.genres.isDisjoint(with: childrensGenres) { return nil }
            return score(candidate, profile: profile)
        }

        let share = personalShare(strength: profile.strength)
        let personalPool = share > 0 ? scored.filter { $0.personal >= 0.3 }
            .sorted { ($0.personal + $0.prior, $0.candidate.item.catalogID) > ($1.personal + $1.prior, $1.candidate.item.catalogID) } : []
        let personal = diversify(personalPool, limit: limit) { $0.personal + $0.prior }
        let taken = Set(personal.map(\.candidate.item.catalogID))

        // Exploratory picks: well-regarded books outside the reader's usual pattern,
        // never ones their ratings or DNFs argue against.
        let topGenres = Set(profile.genres.filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(3).map(\.key))
        let explorePool = scored.filter { !taken.contains($0.candidate.item.catalogID) && $0.personal > -1 }
        let exploratoryScore: (Scored) -> Double = { item in
            let novelty = item.candidate.genres.isDisjoint(with: topGenres) && !item.candidate.genres.isEmpty ? 0.3 : 0
            return item.prior + novelty + 0.6 * DiscoverySeed.unit(seed, item.candidate.item.catalogID)
        }
        let exploratory = diversify(explorePool.sorted { exploratoryScore($0) > exploratoryScore($1) },
                                    limit: limit, score: exploratoryScore)

        var result: [DiscoveryRecommendation] = []
        var p = 0, e = 0
        while result.count < limit, p < personal.count || e < exploratory.count {
            if Task.isCancelled { return [] }
            let wantsPersonal = Double(p) < Double(result.count + 1) * share
            let pick: Scored
            let isPersonal: Bool
            if (wantsPersonal && p < personal.count) || e >= exploratory.count {
                pick = personal[p]; p += 1; isPersonal = true
            } else {
                pick = exploratory[e]; e += 1; isPersonal = false
            }
            result.append(DiscoveryRecommendation(item: pick.candidate.item,
                score: isPersonal ? pick.personal + pick.prior : exploratoryScore(pick),
                personal: isPersonal, reasons: (isPersonal ? ["personal"] : ["exploratory"]) + pick.reasons))
        }
        return result
    }

    /// Greedy re-ranking that spends score to avoid repeating an author or a narrow
    /// genre cluster, so six near-identical books don't arrive together.
    static func diversify(_ sorted: [Scored], limit: Int, score: (Scored) -> Double) -> [Scored] {
        var pool = sorted
        var picked: [Scored] = []
        var authorCounts: [String: Int] = [:]
        while picked.count < limit, !pool.isEmpty {
            if Task.isCancelled { return [] }
            let recent = picked.suffix(3).map(\.candidate.genres)
            var bestIndex = 0
            var bestValue = -Double.infinity
            for index in pool.indices.prefix(40) {
                let candidate = pool[index].candidate
                let author = DiscoveryIdentity.primaryAuthorKey(candidate.item.author)
                let overlap = recent.map { jaccard($0, candidate.genres) }.max() ?? 0
                let value = score(pool[index]) - 2 * Double(authorCounts[author] ?? 0) - 0.8 * overlap
                if value > bestValue { bestValue = value; bestIndex = index }
            }
            let chosen = pool.remove(at: bestIndex)
            authorCounts[DiscoveryIdentity.primaryAuthorKey(chosen.candidate.item.author), default: 0] += 1
            picked.append(chosen)
        }
        return picked
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }
}

/// Explore favors breadth: subject, era, and origin pools are interleaved in a seeded
/// order that changes between sessions but stays stable while browsing and paging.
enum DiscoveryExploreOrder {
    static func order(_ items: [DiscoverItem], seed: UInt64, includeChildrens: Bool = false,
                      genres: ((DiscoverItem) -> Set<String>)? = nil) -> [DiscoverItem] {
        var seen = Set<String>()
        var seenWorks = Set<String>()
        let unique = items.filter { item in
            guard !Task.isCancelled, seen.insert(item.catalogID).inserted else { return false }
            if let work = DiscoveryIdentity.workKey(title: item.title, author: item.author),
               !seenWorks.insert(work).inserted { return false }
            if !includeChildrens,
               !(genres?(item) ?? GenreTaxonomy.normalized(item.subjects, isOpenLibrary: true)).isDisjoint(with: DiscoveryRecommender.childrensGenres) { return false }
            return true
        }
        var pools = Dictionary(grouping: unique) { $0.facet ?? "other" }.mapValues { pool in
            // Weighted shuffle: well-read books tend to lead, but not always the same ones.
            pool.sorted {
                let a = log10(1 + Double($0.popularity)) * 0.35 + DiscoverySeed.unit(seed, $0.catalogID)
                let b = log10(1 + Double($1.popularity)) * 0.35 + DiscoverySeed.unit(seed, $1.catalogID)
                return a == b ? $0.catalogID < $1.catalogID : a > b
            }
        }
        let facets = pools.keys.sorted { DiscoverySeed.unit(seed, "facet:" + $0) < DiscoverySeed.unit(seed, "facet:" + $1) }
        var result: [DiscoverItem] = []
        var recentAuthors: [String] = []
        while pools.values.contains(where: { !$0.isEmpty }) {
            if Task.isCancelled { return [] }
            for facet in facets {
                guard var pool = pools[facet], !pool.isEmpty else { continue }
                // Prefer the next book whose author hasn't appeared in the last dozen picks.
                let index = pool.prefix(4).firstIndex {
                    !recentAuthors.contains(DiscoveryIdentity.primaryAuthorKey($0.author))
                } ?? pool.startIndex
                let item = pool.remove(at: index)
                pools[facet] = pool
                result.append(item)
                recentAuthors.append(DiscoveryIdentity.primaryAuthorKey(item.author))
                if recentAuthors.count > 12 { recentAuthors.removeFirst() }
            }
        }
        return result
    }
}

/// Reproducible pseudo-randomness: SplitMix64 over FNV-1a, independent of Swift's
/// per-process hash seeding, so the same seed gives the same order on every launch.
enum DiscoverySeed {
    static func fnv(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return hash
    }

    static func mix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9e3779b97f4a7c15
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }

    /// A stable value in [0, 1) for this seed and key.
    static func unit(_ seed: UInt64, _ key: String) -> Double {
        Double(mix(seed ^ fnv(key)) >> 11) / Double(1 << 53)
    }

    /// One seed per reader per day: For You stays put across launches the same day.
    static func daily(userID: UUID, date: Date) -> UInt64 {
        let day = Int(date.timeIntervalSince1970 / 86_400)
        return mix(fnv(userID.uuidString) ^ UInt64(day))
    }

    static func signature(_ parts: [String]) -> String {
        String(fnv(parts.joined(separator: "\u{1F}")), radix: 16)
    }
}
