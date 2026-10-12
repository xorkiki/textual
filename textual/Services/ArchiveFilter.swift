import Foundation

enum ArchiveReadingStatus: String, CaseIterable, Identifiable {
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

struct ArchiveFilter: Equatable {
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

struct ArchiveFilterOptions: Equatable {
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
