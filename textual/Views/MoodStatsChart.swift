import SwiftUI

struct MoodStat: Identifiable {
    let name: String
    let color: Color
    var count: Int = 0
    var id: String { name }

    static func counts(readings: [StoryGraphReadingData], filter: ReadingStatsFilter) -> [MoodStat] {
        var result = [
            MoodStat(name: "Dark", color: .bloodletter.opacity(0.3)),
            MoodStat(name: "Tense", color: .bloodletter),
            MoodStat(name: "Adventurous", color: .moss),
            MoodStat(name: "Mysterious", color: .moss.opacity(0.3)),
            MoodStat(name: "Reflective", color: .duskpetal),
            MoodStat(name: "Emotional", color: .duskpetal.opacity(0.3)),
            MoodStat(name: "Inspiring", color: .clayhearth),
            MoodStat(name: "Informative", color: .inkstorm),
            MoodStat(name: "Funny", color: .clayhearth.opacity(0.3)),
            MoodStat(name: "Sad", color: .inkstorm.opacity(0.3))
        ]
        for reading in readings {
            let count = filter.count(reading)
            guard count > 0 else { continue }
            let moods = Set(reading.moods.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.filter { !$0.isEmpty })
            // Preserve all imported labels, not just the initial design palette.
            for name in moods.isEmpty ? ["not recorded"] : moods.sorted() {
                if let index = result.firstIndex(where: { $0.name.lowercased() == name }) {
                    result[index].count += count
                } else {
                    result.append(MoodStat(name: name == "not recorded" ? "Not recorded" : name.capitalized,
                                           color: name == "not recorded" ? .ghost.opacity(0.3) : GenreStat(name: name, count: 0).color,
                                           count: count))
                }
            }
        }
        return result
    }
}

/// Every blob uses the same silhouette at a different scale: area, not diameter,
/// represents its count. Bounding circles keep even the organic edges separate.
struct MoodBubblePacking {
    struct Bubble: Identifiable {
        let id: String
        let radius: CGFloat
        let center: CGPoint
    }
    static func pack(_ values: [(String, Int)]) -> [Bubble] {
        let sorted = values.filter { $0.1 > 0 }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        var placed: [Bubble] = []
        for (name, count) in sorted {
            let radius = sqrt(CGFloat(count))
            guard !placed.isEmpty else {
                placed.append(Bubble(id: name, radius: radius, center: .zero)); continue
            }
            var best: CGPoint = .zero
            var bestScore = CGFloat.infinity
            let gap: CGFloat = 0.035
            for anchor in placed {
                for step in 0..<120 {
                    let angle = CGFloat(step) * .pi * 2 / 120
                    let distance = anchor.radius + radius + gap
                    let candidate = CGPoint(x: anchor.center.x + cos(angle) * distance,
                                            y: anchor.center.y + sin(angle) * distance)
                    guard placed.allSatisfy({ hypot(candidate.x - $0.center.x, candidate.y - $0.center.y) >= radius + $0.radius + gap - 0.00001 }) else { continue }
                    let trial = placed + [Bubble(id: name, radius: radius, center: candidate)]
                    let bounds = bounds(trial)
                    let score = max(bounds.width, bounds.height) * max(bounds.width, bounds.height)
                        + bounds.width * bounds.height * 0.15 + hypot(candidate.x, candidate.y) * 0.01
                    if score < bestScore { bestScore = score; best = candidate }
                }
            }
            if !bestScore.isFinite {
                best = CGPoint(x: placed.map { $0.center.x + $0.radius }.max()! + radius + gap, y: 0)
            }
            placed.append(Bubble(id: name, radius: radius, center: best))
        }
        return placed
    }
    static func bounds(_ bubbles: [Bubble]) -> CGRect {
        guard !bubbles.isEmpty else { return .zero }
        let minX = bubbles.map { $0.center.x - $0.radius }.min()!
        let maxX = bubbles.map { $0.center.x + $0.radius }.max()!
        let minY = bubbles.map { $0.center.y - $0.radius }.min()!
        let maxY = bubbles.map { $0.center.y + $0.radius }.max()!
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

struct MoodStatsChart: View {
    let moods: [MoodStat]
    let onSelect: (String) -> Void

    var body: some View {
        let values = moods.filter { $0.count > 0 }.sorted {
            $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count
        }
        VStack(alignment: .leading, spacing: 24) {
            Text("Moods")
                .font(.custom("CormorantGaramond-Regular", size: 26, relativeTo: .title2))
                .foregroundStyle(Color.paper)
            if values.isEmpty {
                Text("No moods recorded for this selection yet.")
                    .font(.custom("PlusJakartaSans-Regular", size: 14, relativeTo: .body))
                    .foregroundStyle(Color.ghost)
                    .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                GeometryReader { geometry in
                    let tiles = GenreTiles.layout(values.map { GenreStat(name: $0.name, count: $0.count) },
                                                  in: CGRect(origin: .zero, size: geometry.size))
                    ZStack(alignment: .topLeading) {
                        ForEach(tiles) { tile in
                            let color = values.first { $0.id == tile.id }!.color
                            let inset = min(3, min(tile.rect.width, tile.rect.height) * 0.06)
                            let box = tile.rect.insetBy(dx: inset, dy: inset)
                            let corner = min(box.width, box.height) * 0.45
                            RoundedRectangle(cornerRadius: corner, style: .continuous)
                                .fill(color)
                                .frame(width: box.width, height: box.height)
                                .position(x: box.midX, y: box.midY)
                                .onTapGesture { onSelect(tile.id) }
                                .accessibilityAction { onSelect(tile.id) }
                                .accessibilityHint("Show matching books")
                                .accessibilityLabel(tile.genre.name)
                                .accessibilityValue("\(tile.genre.count) books")
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                }
                .frame(height: max(280, min(560, sqrt(Double(values.count)) * 75)))
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 14) {
                ForEach(moods) { mood in
                    Button { onSelect(mood.id) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(mood.color).frame(width: 12, height: 12)
                            Text(mood.name).foregroundStyle(Color.paper)
                            Text(mood.count.formatted()).foregroundStyle(Color.ghost)
                        }
                        .font(.custom("PlusJakartaSans-Regular", size: 12, relativeTo: .caption))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(mood.count == 0)
                    .accessibilityLabel("\(mood.name), \(mood.count) books")
                    .accessibilityHint("Show matching books")
                }
            }
        }
    }
}
