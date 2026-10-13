import SwiftUI
import SwiftData
import Charts

/// Uses the same classifiers as the charts, including their missing-data buckets.
enum StatsBookCategory: Hashable, Identifiable {
    case fiction(BookFictionKind?)
    case mood(String)
    case pace(PaceStat.Pace)
    case genre(String)
    case pages

    var id: Self { self }
    var title: String {
        switch self {
        case .fiction(let kind): return kind?.rawValue ?? "Unclassified"
        case .mood(let name), .genre(let name): return name
        case .pace(let pace): return pace.rawValue
        case .pages: return "Pages"
        }
    }
    var chartTitle: String {
        switch self {
        case .fiction: return "Fiction & nonfiction"
        case .mood: return "Moods"
        case .pace: return "Pace"
        case .genre: return "Genres"
        case .pages: return "Pages"
        }
    }

    func estimateReason(for entry: ReadingBookSnapshot) -> String? {
        switch self {
        case .fiction: return entry.guess.kindReason
        case .genre: return entry.guess.genreReason
        case .mood: return entry.moodEstimateReason
        case .pace: return entry.paceEstimateReason
        case .pages:
            if let reason = entry.pageEstimateReason { return "About \(entry.statsPages) pages · \(reason)" }
            return "\(entry.statsPages) pages · Catalog count"
        }
    }

    @MainActor
    func books(in books: [Book], filter: ReadingStatsFilter, snapshots: [UUID: ReadingBookSnapshot] = [:]) -> [Book] {
        var seen: Set<UUID> = []
        return books.filter { book in
            guard !book.isRemovedFromLibrary, let reading = book.importedReading,
                  filter.count(reading) > 0, seen.insert(book.id).inserted else { return false }
            switch self {
            case .fiction(let kind):
                return (snapshots[book.id]?.statsKind ?? StatsMetadataCache.fictionKind(book)
                    ?? ReadingBookSnapshot(ReadingBookInput(book)).statsKind) == kind
            case .mood(let name):
                return MoodStat.counts(entries: [snapshots[book.id] ?? ReadingBookSnapshot(ReadingBookInput(book))], filter: filter).contains { $0.name == name && $0.count > 0 }
            case .pace(let pace):
                return PaceStat.counts(entries: [snapshots[book.id] ?? ReadingBookSnapshot(ReadingBookInput(book))], filter: filter).contains { $0.pace == pace && $0.count > 0 }
            case .pages: return true
            case .genre(let name):
                let genres = snapshots[book.id]?.statsGenres ?? ReadingBookSnapshot(ReadingBookInput(book)).statsGenres
                return genres.contains(name) || (name == "Unclassified" && genres.isEmpty)
            }
        }.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }
}

/// Sector values are cumulative, in the same order as the chart's marks.
enum StatsSectorSelection {
    static func index(value: Double, counts: [Int]) -> Int? {
        guard value.isFinite, value >= 0 else { return nil }
        var upper = 0.0
        for (index, count) in counts.enumerated() where count > 0 {
            upper += Double(count)
            if value < upper { return index }
        }
        return nil
    }
}

extension View {
    /// A single tap opens a slice, while a drag still scrolls the Stats page.
    func statsSectorSelection(counts: [Int], innerRadius: CGFloat = 0,
                              onSelect: @escaping (Int) -> Void) -> some View {
        chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let frame = geometry[anchor]
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            let point = CGPoint(x: location.x - frame.minX, y: location.y - frame.minY)
                            let radius = min(frame.width, frame.height) / 2
                            let distance = hypot(point.x - frame.width / 2, point.y - frame.height / 2)
                            guard distance <= radius, distance >= radius * innerRadius,
                                  let value = proxy.value(atAngle: proxy.angle(at: point), as: Double.self),
                                  let index = StatsSectorSelection.index(value: value, counts: counts) else { return }
                            onSelect(index)
                        }
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

struct StatsCategoryBooksView: View {
    let category: StatsBookCategory
    let filter: ReadingStatsFilter
    @Query(filter: #Predicate<Book> { !$0.isRemovedFromLibrary }) private var books: [Book]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.readingLibrary) private var cache
    @State private var selectedBook: Book?

    var body: some View {
        // Reuse the worker's decoded estimates; never reclassify the library in a view body.
        let snapshots = Dictionary(uniqueKeysWithValues: (cache?.snapshot.entries ?? []).map { ($0.id, $0) })
        let matches = category.books(in: books, filter: filter, snapshots: snapshots)
        NavigationStack {
            ZStack {
                Color.inkwell.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if !matches.isEmpty {
                            Text("Touch and hold a cover to see its classification or page estimate.")
                                .font(.designSystem(.bodySmall))
                                .foregroundStyle(Color.ghost)
                        }
                        if matches.isEmpty {
                            TextualEmptyState(title: "No matching books", icon: .archive,
                                detail: "There are no books in this category for the selected period.")
                                .foregroundStyle(Color.paper)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 16, alignment: .top)], spacing: 20) {
                                ForEach(matches) { book in
                                    Button { selectedBook = book } label: {
                                        SavedBookCover(book: book, width: 120, height: 180)
                                    }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("\(book.title) by \(book.author)")
                                        .accessibilityHint("Open book details. Touch and hold for classification or page estimates.")
                                        .textualContextMenu(isEnabled: category.estimateReason(for:
                                            snapshots[book.id] ?? ReadingBookSnapshot(ReadingBookInput(book))) != nil) {
                                            let entry = snapshots[book.id] ?? ReadingBookSnapshot(ReadingBookInput(book))
                                            if let reason = category.estimateReason(for: entry) {
                                                Text(reason).fixedSize(horizontal: false, vertical: true).padding(12)
                                            }
                                        }
                                }
                            }
                        }
                    }
                    .padding(24)
                }
            }
            .textualSheetHeader(category.title) { dismiss() }
            .sheet(item: $selectedBook) { book in
                NavigationStack { BookDetailView(book: book, isPresentedAsSheet: true) }
            }
        }
        .preferredColorScheme(.dark)
    }
}
