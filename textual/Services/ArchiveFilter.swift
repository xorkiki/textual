import Foundation

enum ArchiveReadingStatus: String, CaseIterable, Identifiable, Sendable {
    case all = "all", read = "read", tbr = "to-read", reading = "currently-reading", dnf = "did-not-finish"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .reading: return "Reading"
        case .read: return "Read"
        case .tbr: return "TBR"
        case .dnf: return "DNF"
        }
    }
    var accessibleTitle: String {
        switch self {
        case .all: return "All books"
        case .reading: return "Currently reading"
        case .read: return "Read"
        case .tbr: return "To be read"
        case .dnf: return "Did not finish"
        }
    }
}

struct ArchiveFilter: Equatable, Sendable {
    var status: ArchiveReadingStatus = .read
    var genre: String?
    var mood: String?
    var pace: String?

    mutating func reconcile(with options: ArchiveFilterOptions) {
        if let genre, !options.genres.contains(genre) { self.genre = nil }
        if let mood, !options.moods.contains(mood) { self.mood = nil }
        if let pace, !options.paces.contains(pace) { self.pace = nil }
    }
}

struct ArchiveFilterOptions: Equatable, Sendable {
    let genres: [String]
    let moods: [String]
    let paces: [String]
}

/// One local snapshot supplies both the available choices and matching books.
/// Choices come from the entire archive, so combining filters never hides a menu option.
@MainActor
struct ArchiveFilterCatalog {
    private struct Entry {
        let book: Book
        let status: String
        let genres: Set<String>
        let moods: Set<String>
        let pace: String
    }
    private let entries: [Entry]
    let options: ArchiveFilterOptions

    init(books: [Book]) {
        entries = books.filter { !$0.isRemovedFromLibrary }.map { book in
            let reading = book.importedReading
            return Entry(book: book,
                // Newly saved books without reading history start on the to-read shelf.
                status: reading?.status ?? ArchiveReadingStatus.tbr.rawValue,
                genres: StatsMetadataCache.genres(book),
                moods: Set((reading?.moods ?? []).map(Self.label).filter { !$0.isEmpty }),
                pace: Self.label(reading?.pace ?? ""))
        }
        options = ArchiveFilterOptions(
            genres: Self.sorted(entries.flatMap(\.genres)),
            moods: Self.sorted(entries.flatMap(\.moods)),
            paces: Self.sorted(entries.map(\.pace)))
    }

    func books(matching filter: ArchiveFilter) -> [Book] {
        entries.filter { entry in
            (filter.status == .all || entry.status == filter.status.rawValue)
                && (filter.genre.map { entry.genres.contains($0) } ?? true)
                && (filter.mood.map { entry.moods.contains($0) } ?? true)
                && (filter.pace.map { entry.pace == $0 } ?? true)
        }.map(\.book)
    }

    private static func label(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased().capitalized
    }

    private static func sorted(_ values: [String]) -> [String] {
        Set(values.filter { !$0.isEmpty }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// Prepared once per library change, independently of scroll and search rendering.
struct ArchiveSnapshot: Sendable {
    struct Entry: Sendable {
        let id: UUID
        let title: String
        let author: String
        let status: String
        let genres: Set<String>
        let moods: Set<String>
        let pace: String
    }
    let entries: [Entry]
    let options: ArchiveFilterOptions

    init(entries: [ReadingBookSnapshot]) {
        func label(_ value: String) -> String {
            value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased().capitalized
        }
        self.entries = entries.map { entry in
            Entry(id: entry.id, title: entry.input.title, author: entry.input.author,
                  status: entry.reading?.status ?? "to-read", genres: entry.genres,
                  moods: Set((entry.reading?.moods ?? []).map(label).filter { !$0.isEmpty }),
                  pace: label(entry.reading?.pace ?? ""))
        }
        func sorted(_ values: [String]) -> [String] {
            Set(values.filter { !$0.isEmpty }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        options = ArchiveFilterOptions(genres: sorted(self.entries.flatMap(\.genres)),
            moods: sorted(self.entries.flatMap(\.moods)), paces: sorted(self.entries.map(\.pace)))
    }

    func matching(_ filter: ArchiveFilter, search: String = "", excluding: Set<UUID> = []) -> Set<UUID> {
        Set(entries.filter {
            !excluding.contains($0.id)
                && (filter.status == .all || $0.status == filter.status.rawValue)
                && (filter.genre.map($0.genres.contains) ?? true)
                && (filter.mood.map($0.moods.contains) ?? true)
                && (filter.pace == nil || filter.pace == $0.pace)
                && (search.isEmpty || $0.title.localizedStandardContains(search) || $0.author.localizedStandardContains(search))
        }.map(\.id))
    }
}


/// Dates are prepared once per sort; equal/unknown dates have a stable title order.
enum ArchiveSort: String, CaseIterable, Identifiable {
    case title, recentlyAdded, oldestAdded
    var id: String { rawValue }
    var title: String {
        switch self {
        case .title: return "Title A–Z"
        case .recentlyAdded: return "Recently added"
        case .oldestAdded: return "Oldest added"
        }
    }

    @MainActor func sorted(_ books: [Book]) -> [Book] {
        let dated = books.map { (book: $0, date: self == .title ? nil : Self.dateAdded(to: $0)) }
        return dated.sorted { lhs, rhs in
            if self != .title, lhs.date != rhs.date {
                guard let first = lhs.date else { return false }
                guard let second = rhs.date else { return true }
                return self == .recentlyAdded ? first > second : first < second
            }
            let comparison = lhs.book.title.localizedStandardCompare(rhs.book.title)
            return comparison == .orderedSame
                ? lhs.book.id.uuidString < rhs.book.id.uuidString : comparison == .orderedAscending
        }.map(\.book)
    }

    @MainActor static func dateAdded(to book: Book) -> Date? {
        let reading = book.importedReading
        if let raw = reading?.dateAdded, let normalized = StoryGraphImporter.normalizedDate(raw) {
            let parts = normalized.split(separator: "-").compactMap { Int($0) }
            if parts.count == 3 {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                if let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) {
                    return date
                }
            }
        }
        return reading?.libraryAddedAt ?? book.addedAt
    }
}
