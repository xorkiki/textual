import SwiftUI
import Charts

struct PaceStat: Identifiable, Sendable {
    enum Pace: String, CaseIterable, Sendable {
        case fast = "Fast", medium = "Medium", slow = "Slow", unknown = "Not recorded"
        var color: Color {
            switch self {
            case .fast: return .moss
            case .medium: return .inkstorm
            case .slow: return .duskpetal
            case .unknown: return .ghost.opacity(0.3)
            }
        }
    }
    let pace: Pace
    var count: Int
    var estimatedCount: Int = 0
    var id: String { pace.rawValue }

    static func counts(readings: [StoryGraphReadingData], filter: ReadingStatsFilter) -> [PaceStat] {
        let known: [Pace] = [.fast, .medium, .slow]
        var totals: [Pace: Int] = [:]
        for reading in readings {
            let value = reading.pace.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let pace = known.first { $0.rawValue.lowercased() == value } ?? .unknown
            totals[pace, default: 0] += filter.count(reading)
        }
        return (known + ((totals[.unknown] ?? 0) > 0 ? [.unknown] : [])).map {
            PaceStat(pace: $0, count: totals[$0, default: 0])
        }
    }

    static func counts(entries: [ReadingBookSnapshot], filter: ReadingStatsFilter) -> [PaceStat] {
        var result = [PaceStat(pace: .fast, count: 0), PaceStat(pace: .medium, count: 0), PaceStat(pace: .slow, count: 0)]
        for entry in entries {
            guard let reading = entry.reading else { continue }
            let count = filter.count(reading)
            guard count > 0 else { continue }
            let index: Int
            switch entry.pace.value { case .fast: index = 0; case .medium: index = 1; case .slow: index = 2 }
            result[index].count += count
            if entry.paceEstimateReason != nil { result[index].estimatedCount += count }
        }
        return result
    }

    func fraction(total: Int) -> Double? { total > 0 ? Double(count) / Double(total) : nil }
}

struct PaceStatsChart: View {
    let paces: [PaceStat]
    let onSelect: (PaceStat.Pace) -> Void

    var body: some View {
        let total = paces.reduce(0) { $0 + $1.count }
        VStack(alignment: .leading, spacing: 24) {
            Text("Pace")
                .font(.designSystem(.sectionHeading))
                .foregroundStyle(Color.paper)
            if total > 0 {
                Chart {
                    ForEach(paces) { item in
                        if item.count > 0 {
                            SectorMark(angle: .value("Books", item.count), innerRadius: .ratio(0.78), angularInset: 1)
                                .foregroundStyle(item.pace.color)
                                .accessibilityLabel(item.pace.rawValue)
                                .accessibilityValue("\(item.count) books, \(item.fraction(total: total)!.formatted(.percent.precision(.fractionLength(0...1))))")
                        }
                    }
                }
                .statsSectorSelection(counts: paces.map(\.count), innerRadius: 0.78) { index in
                    onSelect(paces[index].pace)
                }
                .chartLegend(.hidden)
                .frame(height: 230)
                .accessibilityLabel("Book pace breakdown for \(total) reads")
            } else {
                Text("No pace recorded for this selection yet.")
                    .font(.designSystem(.bodySmall))
                    .foregroundStyle(Color.ghost)
                    .frame(maxWidth: .infinity, minHeight: 230)
            }
            VStack(spacing: 16) {
                ForEach(paces) { item in
                    Button { onSelect(item.pace) } label: {
                        HStack(spacing: 10) {
                            Circle().fill(item.pace.color).frame(width: 12, height: 12)
                            Text(item.pace.rawValue).foregroundStyle(Color.paper)
                            Spacer(minLength: 12)
                            Text("\(item.count.formatted()) \(item.count == 1 ? "book" : "books")")
                                .foregroundStyle(Color.ghost)
                            Text(item.fraction(total: total).map { $0.formatted(.percent.precision(.fractionLength(0...1))) } ?? "—")
                                .monospacedDigit()
                                .foregroundStyle(Color.paper)
                                .frame(minWidth: 55, alignment: .trailing)
                        }
                        .font(.designSystem(.caption))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(item.count == 0)
                    .accessibilityHint("Show matching books")
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
