import SwiftUI

struct GenreStat: Identifiable, Sendable {
    let name: String
    var count: Int
    var id: String { name }
    var color: Color {
        if name == "Unclassified" { return .ghost.opacity(0.3) }
        let palette: [Color] = [.moss, .inkstorm, .duskpetal, .clayhearth, .bloodletter]
        let hash = name.utf8.reduce(0) { ($0 * 31 + Int($1)) % 100_003 }
        return palette[hash % palette.count]
    }

    /// Compatibility entry point for charts; all classification lives in the shared taxonomy.
    static func normalized(_ categories: [String], isOpenLibrary: Bool) -> Set<String> {
        GenreTaxonomy.normalized(categories, isOpenLibrary: isOpenLibrary)
    }

    static func counts(_ entries: [(genres: Set<String>, count: Int)]) -> [GenreStat] {
        var counts: [String: Int] = [:]
        for entry in entries where entry.count > 0 {
            let genres = entry.genres.isEmpty ? Set(["Unclassified"]) : entry.genres
            for genre in genres { counts[genre, default: 0] += entry.count }
        }
        return counts.map { GenreStat(name: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
    }
}

struct GenreTiles {
    struct Tile: Identifiable {
        let genre: GenreStat
        let rect: CGRect
        var id: String { genre.id }
    }
    static func layout(_ genres: [GenreStat], in rect: CGRect) -> [Tile] {
        let genres = genres.filter { $0.count > 0 }
        guard !genres.isEmpty else { return [] }
        guard genres.count > 1 else { return [Tile(genre: genres[0], rect: rect)] }
        let total = genres.reduce(0) { $0 + $1.count }
        var running = 0
        var split = 1
        var difference = Double.infinity
        for index in 1..<genres.count {
            running += genres[index - 1].count
            let candidate = abs(Double(running) - Double(total) / 2)
            if candidate < difference { difference = candidate; split = index }
        }
        let first = Array(genres.prefix(split)), second = Array(genres.dropFirst(split))
        let fraction = CGFloat(first.reduce(0) { $0 + $1.count }) / CGFloat(total)
        let a: CGRect, b: CGRect
        if rect.width >= rect.height {
            let width = rect.width * fraction
            a = CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
            b = CGRect(x: rect.minX + width, y: rect.minY, width: rect.width - width, height: rect.height)
        } else {
            let height = rect.height * fraction
            a = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height)
            b = CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: rect.height - height)
        }
        return layout(first, in: a) + layout(second, in: b)
    }
}

struct GenreStatsChart: View {
    let genres: [GenreStat]
    /// Nil for a visitor's read-only breakdown: rows show values without opening books.
    let onSelect: ((String) -> Void)?

    var body: some View {
        let values = genres
        VStack(alignment: .leading, spacing: 24) {
            Text("Genres")
                .font(.designSystem(.sectionHeading))
                .foregroundStyle(Color.paper)
            if values.isEmpty {
                Text("No genres available for this selection yet.")
                    .font(.designSystem(.bodySmall))
                    .foregroundStyle(Color.ghost)
                    .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                GenreBarChart(genres: values, onSelect: onSelect)
            }
        }
    }
}

private struct GenreBarChart: View {
    let genres: [GenreStat]
    let onSelect: ((String) -> Void)?
    @ScaledMetric(relativeTo: .caption) private var rowHeight: CGFloat = 44

    var body: some View {
        let maximum = max(genres.map(\.count).max() ?? 1, 1)
        VStack(spacing: 6) {
            ForEach(genres) { genre in
                if let onSelect {
                    Button { onSelect(genre.name) } label: { row(genre, maximum: maximum) }
                        .buttonStyle(.plain)
                        .disabled(genre.count == 0)
                        .accessibilityHint("Show matching books")
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { onSelect(genre.name) }
                        .accessibilityLabel(genre.name)
                        .accessibilityValue("\(genre.count) books")
                } else {
                    row(genre, maximum: maximum)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(genre.name)
                        .accessibilityValue("\(genre.count) books")
                }
            }
        }
    }

    private func row(_ genre: GenreStat, maximum: Int) -> some View {
        HStack(spacing: 12) {
            Text(genre.name)
                .font(.designSystem(.uiLabel))
                .foregroundStyle(Color.paper)
                .frame(width: 104, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.paper.opacity(0.04))
                    Capsule()
                        .fill(genre.color)
                        .frame(width: geometry.size.width * CGFloat(genre.count) / CGFloat(maximum))
                }
            }
            .frame(height: 16)
            Text(genre.count.formatted())
                .font(.designSystem(.uiLabel))
                .monospacedDigit()
                .foregroundStyle(Color.ghost)
                .frame(minWidth: 26, alignment: .trailing)
        }
        .frame(minHeight: rowHeight)
        .contentShape(Rectangle())
    }
}
