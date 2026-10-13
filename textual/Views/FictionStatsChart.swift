import SwiftUI
import Charts

/// Only explicit catalog classifications are used; an unrecognized subject stays unknown.
enum BookFictionKind: String, CaseIterable, Sendable {
    case fiction = "Fiction", nonfiction = "Nonfiction"

    static func classify(_ categories: [String]) -> Self? {
        let values = categories.map {
            $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "–", with: "-")
        }
        func result(_ fiction: Bool, _ nonfiction: Bool) -> Self? {
            guard fiction != nonfiction else { return nil }
            return fiction ? .fiction : .nonfiction
        }
        // Formal catalog classifications take precedence over loose topical subjects.
        // A novel can have subjects such as History or Biography without being nonfiction.
        let formalFiction = values.contains { $0.hasPrefix("fiction /") || $0.hasPrefix("juvenile fiction /") || $0.hasPrefix("young adult fiction /") }
        let formalNonfiction = values.contains { $0.hasPrefix("nonfiction /") || $0.hasPrefix("non-fiction /") || $0.hasPrefix("juvenile nonfiction /") || $0.hasPrefix("young adult nonfiction /") }
        let explicitNonfiction = values.contains { ["nonfiction", "non-fiction", "non fiction", "juvenile nonfiction", "young adult nonfiction"].contains($0) }
        let explicitFiction = values.contains { ["fiction", "juvenile fiction", "young adult fiction"].contains($0) }
        if formalFiction || formalNonfiction {
            return result(formalFiction || explicitFiction, formalNonfiction || explicitNonfiction)
        }
        let lists = values.filter { $0.hasPrefix("nyt:") }.compactMap { $0.split(separator: "=").first.map(String.init) }
        let listNonfiction = lists.contains { $0.contains("nonfiction") || $0.contains("non-fiction") }
        let listFiction = lists.contains { !$0.contains("nonfiction") && !$0.contains("non-fiction") && $0.contains("fiction") }
        if listFiction || listNonfiction { return result(listFiction, listNonfiction) }
        func matches(_ value: String, _ root: String) -> Bool {
            value == root || value.hasPrefix(root + " /") || value.hasPrefix(root + ",")
        }
        let nonfictionRoots = ["nonfiction", "non-fiction", "non fiction", "juvenile nonfiction", "young adult nonfiction", "biography", "biographies", "biography & autobiography", "autobiography", "autobiographies", "memoir", "memoirs", "history", "philosophy", "psychology", "science", "social science", "religion", "self-help", "self help", "self-realization", "conduct of life", "business", "business & economics", "essays", "literary criticism", "travel", "cooking", "reference", "art", "health & fitness", "true crime", "education", "political science", "computers", "technology & engineering"]
        let fictionRoots = ["fiction", "juvenile fiction", "young adult fiction", "fantasy", "fantasy fiction", "science fiction", "historical fiction", "detective and mystery stories", "romance", "romance fiction", "mystery", "thriller", "thrillers", "horror fiction", "short stories", "novel", "novels", "love stories"]
        let fiction = values.contains { value in
            fictionRoots.contains { matches(value, $0) } || value.hasSuffix(", fiction") || value.hasSuffix("--fiction.")
        }
        let nonfiction = values.contains { value in
            nonfictionRoots.contains { matches(value, $0) } || value.hasSuffix(", biography") || value.hasSuffix("--biography")
        }
        return result(fiction, nonfiction)
    }

    var color: Color {
        switch self {
        case .fiction: return Color.inkstorm
        case .nonfiction: return Color.clayhearth
        }
    }
}

/// Shared scope for every statistic on the Stats page. All time includes undated books;
/// dated charts use only recorded events, never invented completion dates.
struct ReadingStatsFilter: Hashable, Sendable {
    let status: String
    let year: Int?

    static func date(_ raw: String?) -> Date? {
        guard let raw, let normalized = StoryGraphImporter.normalizedDate(raw) else { return nil }
        let parts = normalized.split(separator: "-").compactMap { Int($0) }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Read history survives a later move to TBR, currently reading, or DNF.
    static func completedDates(_ reading: StoryGraphReadingData) -> [Date] {
        if reading.readCount == 0 && reading.status != "read" { return [] }
        let dates = reading.periods.compactMap { period -> Date? in
            guard let finish = date(period.finishedOn) else { return nil }
            if let start = date(period.startedOn), start > finish { return nil }
            return finish
        }
        // Keep separate reads on the same day; a date alone is not an event ID.
        return dates.isEmpty ? [date(reading.lastDateRead)].compactMap { $0 } : dates
    }

    static func completedCount(_ reading: StoryGraphReadingData) -> Int {
        if reading.readCount == 0 && reading.status != "read" { return 0 }
        return max(reading.readCount ?? 0, completedDates(reading).count, reading.status == "read" ? 1 : 0)
    }

    func dates(for reading: StoryGraphReadingData) -> [Date] {
        let dates: [Date]
        switch status {
        case "read": dates = Self.completedDates(reading)
        case "to-read": dates = [Self.date(reading.dateAdded)].compactMap { $0 }
        default: dates = [] // The export does not identify the date a book was abandoned.
        }
        return dates.filter { year == nil || Calendar(identifier: .gregorian).component(.year, from: $0) == year }
    }

    func count(_ reading: StoryGraphReadingData) -> Int {
        guard includes(reading) else { return 0 }
        if status != "read" { return 1 }
        return year == nil ? Self.completedCount(reading) : dates(for: reading).count
    }

    func averageDaysToFinish(_ readings: [StoryGraphReadingData]) -> Double? {
        guard status == "read" else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ raw: String?) -> Date? {
            guard let raw, let normalized = StoryGraphImporter.normalizedDate(raw) else { return nil }
            let parts = normalized.split(separator: "-").compactMap { Int($0) }
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        }
        let durations = readings.filter { includes($0) }.flatMap { reading -> [Int] in
            return reading.periods.compactMap { period in
                guard let start = date(period.startedOn), let finish = date(period.finishedOn),
                      finish >= start, year == nil || calendar.component(.year, from: finish) == year else { return nil }
                return calendar.dateComponents([.day], from: start, to: finish).day.map { $0 + 1 }
            }
        }
        guard !durations.isEmpty else { return nil }
        return Double(durations.reduce(0, +)) / Double(durations.count)
    }

    func includes(_ reading: StoryGraphReadingData) -> Bool {
        let matches = status == "read" ? Self.completedCount(reading) > 0 : reading.status == status
        return matches && (year == nil || !dates(for: reading).isEmpty)
    }
}

/// One snapshot drives totals, both charts, and their shared filter scope.
struct ReadingStatsSnapshot: Sendable {
    struct Entry: Sendable {
        let dates: [Date]
        let count: Int
        let pages: Int?
        let kind: BookFictionKind?
        var pagesEstimated = false
    }
    struct Bucket: Identifiable {
        let date: Date
        var books = 0
        var pages = 0
        var knownPages = 0
        var estimatedPages = 0
        var id: Date { date }
    }
    let entries: [Entry]
    let year: Int?
    var bookCount: Int { entries.reduce(0) { $0 + $1.count } }
    var pageCount: Int { entries.reduce(0) { $0 + ($1.pages ?? 0) * $1.count } }
    var unclassifiedCount: Int { entries.filter { $0.kind == nil }.reduce(0) { $0 + $1.count } }
    var hasPages: Bool { entries.contains { $0.pages != nil } }
    var completePages: Bool { !entries.isEmpty && entries.allSatisfy { $0.pages != nil && !$0.pagesEstimated } }
    var estimatedPageReads: Int { entries.filter(\.pagesEstimated).reduce(0) { $0 + $1.count } }
    var pageTotalDetail: String { estimatedPageReads > 0 ? "Includes estimates" : (completePages ? "Total" : "Partial") }
    func count(_ kind: BookFictionKind) -> Int { entries.filter { $0.kind == kind }.reduce(0) { $0 + $1.count } }

    var buckets: [Bucket] {
        let calendar = Calendar(identifier: .gregorian)
        let unit: Calendar.Component = year == nil ? .year : .month
        let start: Date
        let end: Date
        if let year {
            start = calendar.date(from: DateComponents(year: year, month: 1))!
            end = calendar.date(from: DateComponents(year: year, month: 12))!
        } else {
            let dates = entries.flatMap(\.dates)
            guard let first = dates.min(), let last = dates.max() else { return [] }
            start = calendar.dateInterval(of: .year, for: first)!.start
            end = calendar.dateInterval(of: .year, for: last)!.start
        }
        let distance = calendar.dateComponents([unit], from: start, to: end).value(for: unit) ?? 0
        var totals: [Date: Bucket] = [:]
        for entry in entries {
            for date in entry.dates {
                guard year == nil || calendar.component(.year, from: date) == year else { continue }
                let key = calendar.dateInterval(of: unit, for: date)!.start
                var bucket = totals[key, default: Bucket(date: key)]
                bucket.books += 1
                if let pages = entry.pages {
                    bucket.pages += pages
                    if entry.pagesEstimated { bucket.estimatedPages += 1 } else { bucket.knownPages += 1 }
                }
                totals[key] = bucket
            }
        }
        return (0...distance).compactMap { calendar.date(byAdding: unit, value: $0, to: start) }
            .map { totals[$0, default: Bucket(date: $0)] }
    }
}

/// All chart data is derived together from the active account's library and scope.
struct UserReadingStats: Sendable {
    let totals: ReadingStatsSnapshot
    let genres: [GenreStat]
    let moods: [MoodStat]
    let paces: [PaceStat]
    let averageDays: Double?

    @MainActor init(books: [Book], filter: ReadingStatsFilter) {
        self.init(entries: books.filter { !$0.isRemovedFromLibrary }.map { ReadingBookSnapshot(ReadingBookInput($0)) }, filter: filter)
    }

    init(entries: [ReadingBookSnapshot], filter: ReadingStatsFilter) {
        let entries = entries.filter { $0.reading.map { filter.count($0) > 0 } == true }
        let readings = entries.compactMap(\.reading)
        totals = ReadingStatsSnapshot(entries: entries.compactMap { entry in
            guard let reading = entry.reading else { return nil }
            let dates = filter.dates(for: reading)
            return .init(dates: filter.status == "read" ? dates : Array(dates.sorted().suffix(1)),
                         count: filter.count(reading), pages: entry.statsPages, kind: entry.statsKind, pagesEstimated: entry.pageEstimateReason != nil)
        }, year: filter.year)
        genres = GenreStat.counts(entries.compactMap { entry in
            entry.reading.map { (entry.statsGenres, filter.count($0)) }
        })
        moods = MoodStat.counts(entries: entries, filter: filter)
        paces = PaceStat.counts(entries: entries, filter: filter)
        averageDays = filter.averageDaysToFinish(readings)
    }
}

struct CachedReadingStatsCharts: View {
    let books: [Book]
    let filter: ReadingStatsFilter
    @Environment(\.readingLibrary) private var cache
    @State private var prepared: UserReadingStats?
    @State private var preparedFilter: ReadingStatsFilter?
    private struct Key: Equatable { let revision: Int; let filter: ReadingStatsFilter }

    var body: some View {
        Group {
            if let prepared, preparedFilter == filter {
                ReadingStatsCharts(books: books, filter: filter, stats: prepared)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 240).tint(.paper)
            }
        }
        .task(id: Key(revision: cache?.snapshot.revision ?? 0, filter: filter)) {
            let result: UserReadingStats
            if let cache {
                guard cache.isReady else { return }
                result = await cache.worker.stats(for: cache.snapshot, filter: filter)
            } else {
                // Standalone previews have no account host.
                let inputs = books.filter { !$0.isRemovedFromLibrary }.map(ReadingBookInput.init)
                let worker = ReadingLibraryWorker()
                guard let snapshot = try? await worker.prepare(inputs) else { return }
                result = await worker.stats(for: snapshot, filter: filter)
            }
            guard !Task.isCancelled else { return }
            prepared = result
            preparedFilter = filter
        }
    }
}

struct ReadingStatsCharts: View {
    let books: [Book]
    let filter: ReadingStatsFilter
    let stats: UserReadingStats
    @State private var selectedCategory: StatsBookCategory?

    var body: some View {
        let data = stats.totals
        VStack(alignment: .leading, spacing: 36) {
            summary(data, average: stats.averageDays)
            VStack(alignment: .leading, spacing: 20) {
                heading("Fiction & nonfiction")
                if data.bookCount > 0 {
                    Chart {
                        ForEach(BookFictionKind.allCases, id: \.rawValue) { kind in
                            if data.count(kind) > 0 {
                                SectorMark(angle: .value("Books", data.count(kind)), angularInset: 2)
                                    .foregroundStyle(kind.color)
                                    .accessibilityLabel(kind.rawValue)
                                    .accessibilityValue("\(data.count(kind)) books")
                            }
                        }
                        if data.unclassifiedCount > 0 {
                            SectorMark(angle: .value("Books", data.unclassifiedCount), angularInset: 2)
                                .foregroundStyle(Color.ghost.opacity(0.3))
                                .accessibilityLabel("Unclassified")
                                .accessibilityValue("\(data.unclassifiedCount) books")
                        }
                    }
                    .statsSectorSelection(counts: BookFictionKind.allCases.map { data.count($0) } + [data.unclassifiedCount]) { index in
                        selectedCategory = .fiction(index < BookFictionKind.allCases.count ? BookFictionKind.allCases[index] : nil)
                    }
                    .chartLegend(.hidden)
                    .frame(height: 230)
                    .accessibilityLabel("Fiction, nonfiction, and unclassified books")
                } else {
                    emptyChart
                }
                HStack(spacing: 24) {
                    ForEach(BookFictionKind.allCases, id: \.rawValue) { kind in
                        Button { selectedCategory = .fiction(kind) } label: {
                            legend("\(kind.rawValue) · \(data.count(kind))", color: kind.color)
                                .frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(data.count(kind) == 0)
                        .accessibilityHint("Show matching books")
                    }
                }
                .frame(maxWidth: .infinity)
                if data.unclassifiedCount > 0 {
                    Button { selectedCategory = .fiction(nil) } label: {
                        legend("Unclassified · \(data.unclassifiedCount)", color: Color.ghost.opacity(0.3))
                            .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Show matching books")
                }
            }
            MoodStatsChart(moods: stats.moods) { selectedCategory = .mood($0) }
            PaceStatsChart(paces: stats.paces) { selectedCategory = .pace($0) }
            GenreStatsChart(genres: stats.genres) { selectedCategory = .genre($0) }
        }
        .sheet(item: $selectedCategory) { category in
            StatsCategoryBooksView(category: category, filter: filter)
        }
    }

    private func summary(_ data: ReadingStatsSnapshot, average: Double?) -> some View {
        let bookLabel = filter.status == "read" ? "Books read" : (filter.status == "to-read" ? "To be read" : "Unfinished")
        let pageLabel = "Pages"
        return ViewThatFits(in: .horizontal) {
            StatsSummaryLayout() {
                metric(data.bookCount.formatted(), label: bookLabel, accent: .duskpetal)
                    .padding(.horizontal, 12)
                Button { selectedCategory = .pages } label: {
                    metric(data.hasPages ? data.pageCount.formatted() : "—", label: pageLabel, accent: .moss, detail: data.pageTotalDetail)
                }
                    .buttonStyle(.plain)
                    .accessibilityHint("Show page counts and estimates for matching books")
                    .padding(.horizontal, 12)
                    .overlay(alignment: .leading) { summaryDivider }
                metric(average.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "—",
                       label: "Days to finish", accent: .clayhearth, detail: "Average")
                    .padding(.horizontal, 12)
                    .overlay(alignment: .leading) { summaryDivider }
            }
            VStack(alignment: .leading, spacing: 24) {
                metric(data.bookCount.formatted(), label: bookLabel, accent: .duskpetal)
                Button { selectedCategory = .pages } label: {
                    metric(data.hasPages ? data.pageCount.formatted() : "—", label: pageLabel, accent: .moss, detail: data.pageTotalDetail)
                }
                    .buttonStyle(.plain)
                    .accessibilityHint("Show page counts and estimates for matching books")
                metric(average.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "—",
                       label: "Days to finish", accent: .clayhearth, detail: "Average")
            }
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .background(Color.controlSurface, in: RoundedRectangle(cornerRadius: TextualLayout.menuRadius))
    }

    private var summaryDivider: some View {
        Rectangle().fill(Color.ghost.opacity(0.18)).frame(width: 1).padding(.vertical, 4)
    }

    private func metric(_ value: String, label: String, accent: Color, detail: String = "Total") -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Capsule().fill(accent).frame(width: 20, height: 3)
                .padding(.bottom, 3)
            Text(value)
                .font(.designSystem(.metric))
                .monospacedDigit()
                .foregroundStyle(Color.paper)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(label)
                .font(.designSystem(.metricLabel))
                .foregroundStyle(Color.paper)
                .fixedSize(horizontal: true, vertical: false)
            Text(detail.uppercased())
                .font(.designSystem(.chartAnnotation))
                .tracking(1.2)
                .foregroundStyle(Color.ghost)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(detail) \(label)")
        .accessibilityValue(value == "—" ? "Not available" : value)
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.designSystem(.sectionHeading)).foregroundStyle(Color.paper)
    }
    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 12, height: 12)
            Text(title).font(.designSystem(.caption)).foregroundStyle(Color.paper)
        }
    }
    private var emptyChart: some View {
        VStack(spacing: 12) {
            Text("No data for this selection yet.")
                .font(.designSystem(.bodySmall)).foregroundStyle(Color.ghost)
        }.frame(maxWidth: .infinity, minHeight: 200)
    }

}

/// Preserve natural number widths, then distribute spare room equally between cells.
/// All cells receive the same padding and top alignment; pages can be wider.
private struct StatsSummaryLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let naturalWidth = sizes.reduce(CGFloat.zero) { $0 + $1.width }
        return CGSize(width: max(naturalWidth, proposal.width ?? naturalWidth), height: sizes.map(\.height).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let naturalWidth = sizes.reduce(CGFloat.zero) { $0 + $1.width }
        let extra = max(0, bounds.width - naturalWidth) / CGFloat(max(1, subviews.count))
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let width = sizes[index].width + extra
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width
        }
    }
}
