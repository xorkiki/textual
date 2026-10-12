import Foundation

/// Display-only cleanup; the original catalog metadata remains available for other uses.
enum BookDetailPresentation {
    static func description(_ raw: String?) -> String? {
        guard let raw else { return nil }
        // Open Library appends edition lists after a dashed rule, sometimes inline.
        let divider = raw.range(of: #"[-–—]{3,}|(?m)^\s*(?:-\s+){2,}-\s*$|(?i)<hr\b[^>]*>"#,
                                options: .regularExpression)
        let text = String(raw[..<(divider?.lowerBound ?? raw.endIndex)])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleText = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return visibleText.isEmpty ? nil : text
    }

    static func categories(_ raw: [String], title: String?, description: String?) -> [String] {
        let context = words([title, self.description(description)].compactMap { $0 }.joined(separator: " "))
        var candidates: [Category] = []
        var seen = Set<String>()

        for value in raw {
            guard let label = label(value) else { continue }
            let identity = key(label)
            guard seen.insert(identity).inserted else { continue }
            let families = GenreTaxonomy.normalized([label], isOpenLibrary: true)
            let overlap = words(label).union(words(value)).intersection(context).count
            // Prefer recognizable subjects and topics supported by the book's own synopsis.
            // Keep provider order as the tie-breaker when no stronger evidence is available.
            let score = (families.isEmpty ? 0 : 20) + min(overlap, 3) * 15
            candidates.append(Category(label: label, key: identity, families: families, score: score))
        }

        // A specific subject already conveys its parent (e.g. Chinese Philosophy → Philosophy).
        let all = candidates
        candidates.removeAll { candidate in
            all.contains { other in
                other.key != candidate.key && (" " + other.key + " ").contains(" " + candidate.key + " ")
            }
        }

        var selected: [Category] = []
        while !candidates.isEmpty && selected.count < 5 {
            let usedFamilies = Set(selected.flatMap(\.families))
            func score(_ category: Category) -> Int {
                category.score - (category.families.isDisjoint(with: usedFamilies) ? 0 : 20)
            }
            var best = 0
            for index in candidates.indices.dropFirst() where score(candidates[index]) > score(candidates[best]) {
                best = index
            }
            selected.append(candidates.remove(at: best))
        }
        return selected.map(\.label)
    }

    private struct Category {
        let label: String
        let key: String
        let families: Set<String>
        let score: Int
    }

    private static func label(_ value: String) -> String? {
        let trimmed = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = key(trimmed)
        guard !normalized.isEmpty,
              !["general", "reference", "fiction", "nonfiction", "non fiction", "unknown", "unclassified"].contains(normalized),
              trimmed.range(of: #"(?i)^(?:bg-|bisac|bics|ol\d)|language materials|ouvrages avant|accessible book|protected daisy|in library|large type books"#,
                            options: .regularExpression) == nil else { return nil }

        // Collapse common spelling/translation variants into one subject chip.
        if ["tao", "taoism", "taoisme", "daoism", "daoist", "taoist"].contains(normalized) { return "Taoism" }
        if ["sci fi", "scifi", "science fiction"].contains(normalized) { return "Science fiction" }

        let parts = trimmed.components(separatedBy: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !["", "general", "fiction", "nonfiction", "non fiction"].contains(key($0)) }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " / ")
    }

    private static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func words(_ text: String) -> Set<String> {
        let stopWords: Set<String> = ["the", "and", "for", "with", "from", "this", "that", "into", "about", "their", "are", "was", "his", "her", "its", "book", "books", "general", "fiction"]
        return Set(key(text).split(separator: " ").map(String.init).filter { $0.count > 2 && !stopWords.contains($0) })
    }
}
