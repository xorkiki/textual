import SwiftUI
import SwiftData
import Charts

/// Uses the same classifiers as the charts, including their missing-data buckets.
enum StatsBookCategory: Hashable, Identifiable {
    case fiction(BookFictionKind?)
    case mood(String)
    case pace(PaceStat.Pace)
    case genre(String)

    var id: Self { self }
    var title: String {
        switch self {
        case .fiction(let kind): return kind?.rawValue ?? "Unclassified"
        case .mood(let name), .genre(let name): return name
        case .pace(let pace): return pace.rawValue
        }
    }
    var chartTitle: String {
        switch self {
        case .fiction: return "Fiction & nonfiction"
        case .mood: return "Moods"
        case .pace: return "Pace"
        case .genre: return "Genres"
        }
    }

    @MainActor
    func books(in books: [Book], filter: ReadingStatsFilter) -> [Book] {
        var seen: Set<UUID> = []
        return books.filter { book in
            guard !book.isRemovedFromLibrary, let reading = book.importedReading,
                  filter.count(reading) > 0, seen.insert(book.id).inserted else { return false }
            switch self {
            case .fiction(let kind):
                return StatsMetadataCache.fictionKind(book) == kind
            case .mood(let name):
                return MoodStat.counts(readings: [reading], filter: filter).contains { $0.name == name && $0.count > 0 }
            case .pace(let pace):
                return PaceStat.counts(readings: [reading], filter: filter).contains { $0.pace == pace && $0.count > 0 }
            case .genre(let name):
                let genres = StatsMetadataCache.genres(book)
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
    @State private var selectedBook: Book?

    var body: some View {
        let matches = category.books(in: books, filter: filter)
        NavigationStack {
            ZStack {
                Color.inkwell.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if matches.isEmpty {
                            ContentUnavailableView("No matching books", systemImage: "books.vertical",
                                description: Text("There are no books in this category for the selected period."))
                                .foregroundStyle(Color.paper)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 16, alignment: .top)], spacing: 20) {
                                ForEach(matches) { book in
                                    Button { selectedBook = book } label: { BookGridItem(book: book) }
                                        .buttonStyle(.plain)
                                        .accessibilityHint("Open book details")
                                }
                            }
                        }
                    }
                    .padding(24)
                }
            }
            .textualBackHeader(title: category.title, backLabel: "Back to Stats") { dismiss() }
            .sheet(item: $selectedBook) { book in
                NavigationStack { BookDetailView(book: book) }
            }
        }
        .preferredColorScheme(.dark)
    }
}
