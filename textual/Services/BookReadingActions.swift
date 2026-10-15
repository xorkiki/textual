import Foundation
import SwiftData

struct ReadingJournal: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        var text: String
        var createdAt = Date()
        var page: Int? = nil
    }
    struct Progress: Codable, Equatable, Sendable {
        enum Unit: String, Codable, CaseIterable, Sendable { case page, percent }
        var value: Int
        var unit: Unit
        var label: String { unit == .page ? "Page \(value)" : "\(value)%" }
    }
    var progress: Progress?
    var quotes: [Entry] = []
    var notes: [Entry] = []
}

/// Archive membership statuses use the existing reading-data values.
enum BookAddStatus: String, CaseIterable, Identifiable {
    case read = "read"
    case currentlyReading = "currently-reading"
    case tbr = "to-read"
    case dnf = "did-not-finish"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .read: return "Read"
        case .currentlyReading: return "Currently reading"
        case .tbr: return "TBR"
        case .dnf: return "DNF"
        }
    }
    var accessibleTitle: String {
        switch self {
        case .tbr: return "To be read"
        case .dnf: return "Did not finish"
        default: return title
        }
    }
    var icon: DesignSystemIcon {
        switch self {
        case .read: return .checkmark
        case .currentlyReading: return .openBook
        case .tbr: return .bookmark
        case .dnf: return .close
        }
    }
    var menuAction: HoldSlideAction { .init(id: rawValue, title: title, icon: icon) }
}

enum BookQuickAction: String, CaseIterable, Identifiable {
    case quote, progress, finish, note
    var id: String { rawValue }
    var title: String {
        switch self {
        case .quote: return "Save quote"
        case .progress: return "Update progress"
        case .finish: return "Finish + rate"
        case .note: return "Add note"
        }
    }
    var icon: DesignSystemIcon {
        switch self {
        case .quote: return .quote
        case .progress: return .pieChart
        case .finish: return .star
        case .note: return .edit
        }
    }
    var menuAction: HoldSlideAction { .init(id: rawValue, title: title, icon: icon) }
}

/// A reader action that can become friends' activity. Progress updates, notes, and
/// edits are deliberately absent: they never publish.
enum ReadingActivity: Equatable, Sendable {
    case started, finished
    case quote(UUID)
}

struct BookActionRoute: Identifiable {
    let id = UUID()
    let book: Book
    let action: BookQuickAction
    var editingEntry: ReadingJournal.Entry? = nil
}

/// My quotes groups saved quotes by book, newest quote first. Search matches the
/// title or author (showing every quote) or the quote text (showing only matches).
enum ReadingQuoteRows {
    static func rows(books: [Book], search: String) -> [(book: Book, quotes: [ReadingJournal.Entry])] {
        let search = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return books.compactMap { book -> (book: Book, quotes: [ReadingJournal.Entry])? in
            let quotes = (book.importedReading?.journal?.quotes ?? []).sorted { $0.createdAt > $1.createdAt }
            guard !quotes.isEmpty else { return nil }
            if search.isEmpty || book.title.localizedCaseInsensitiveContains(search)
                || book.author.localizedCaseInsensitiveContains(search) { return (book, quotes) }
            let matches = quotes.filter { $0.text.localizedCaseInsensitiveContains(search) }
            return matches.isEmpty ? nil : (book, matches)
        }
        .sorted { $0.quotes[0].createdAt > $1.quotes[0].createdAt }
    }
}

/// All quick sheets and full reading controls share the same mutation path and
/// the existing account-private library outbox (including offline/conflict handling).
@MainActor
enum BookReadingActions {
    /// Stage initial membership before the repository saves the book and its outbox.
    /// Adding a previously read book is not evidence that it was finished today.
    static func prepareArchiveStatus(_ status: BookAddStatus, for book: Book) throws {
        var reading = UpNextQueue.metadata(for: book)
        reading.status = status.rawValue
        reading.upNextPosition = nil
        reading.upNextExcluded = true
        if status == .read {
            var journal = reading.journal ?? .init()
            journal.progress = .init(value: 100, unit: .percent)
            reading.journal = journal
        }
        book.storyGraphData = try JSONEncoder().encode(reading)
    }

    static func updateProgress(_ value: Int, unit: ReadingJournal.Progress.Unit, book: Book,
                               context: ModelContext, repository: LibraryRepository?) throws {
        guard value >= 0, value <= (unit == .percent ? 100 : 1_000_000) else {
            throw ReadingActionError.invalidProgress
        }
        try save(book, context: context, repository: repository) { reading in
            var journal = reading.journal ?? .init()
            journal.progress = .init(value: value, unit: unit)
            reading.journal = journal
        }
    }

    static func append(_ text: String, page: Int? = nil, action: BookQuickAction, book: Book,
                       context: ModelContext, repository: LibraryRepository?) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4_000, action == .quote || action == .note else {
            throw ReadingActionError.invalidText
        }
        var entry = ReadingJournal.Entry(text: text)
        if action == .quote { entry.page = page }
        try save(book, context: context, repository: repository,
                 activity: action == .quote ? [.quote(entry.id)] : []) { reading in
            var journal = reading.journal ?? .init()
            if action == .quote { journal.quotes.append(entry) }
            else { journal.notes.append(entry) }
            reading.journal = journal
        }
    }

    static func updateEntry(id: UUID, text: String, page: Int?, action: BookQuickAction, book: Book,
                            context: ModelContext, repository: LibraryRepository?) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4_000, action == .quote || action == .note else {
            throw ReadingActionError.invalidText
        }
        try save(book, context: context, repository: repository) { reading in
            var journal = reading.journal ?? .init()
            if action == .quote {
                guard let index = journal.quotes.firstIndex(where: { $0.id == id }) else { return }
                journal.quotes[index].text = text
                journal.quotes[index].page = page
                // createdAt is intentionally preserved
            } else {
                guard let index = journal.notes.firstIndex(where: { $0.id == id }) else { return }
                journal.notes[index].text = text
            }
            reading.journal = journal
        }
    }

    static func deleteEntry(id: UUID, action: BookQuickAction, book: Book,
                            context: ModelContext, repository: LibraryRepository?) throws {
        guard action == .quote || action == .note else { return }
        try save(book, context: context, repository: repository) { reading in
            var journal = reading.journal ?? .init()
            if action == .quote { journal.quotes.removeAll { $0.id == id } }
            else { journal.notes.removeAll { $0.id == id } }
            reading.journal = journal
        }
    }

    static func setStatus(_ status: String, book: Book, context: ModelContext,
                          repository: LibraryRepository?, now: Date = Date()) throws {
        guard ["currently-reading", "read", "to-read", "did-not-finish"].contains(status) else {
            throw ReadingActionError.invalidStatus
        }
        let previous = UpNextQueue.metadata(for: book).status
        var activity: [ReadingActivity] = []
        if status == "currently-reading", previous != "currently-reading" { activity.append(.started) }
        if status == "read", previous != "read" { activity.append(.finished) }
        try save(book, context: context, repository: repository, activity: activity) { reading in
            if status == "read", reading.status != "read" {
                let formatter = DateFormatter()
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd"
                let date = formatter.string(from: now)
                reading.lastDateRead = date
                reading.readCount = min(1_000_000, max(0, reading.readCount ?? 0) + 1)
                if let index = reading.periods.lastIndex(where: { $0.finishedOn == nil }) {
                    reading.periods[index].finishedOn = date
                } else { reading.periods.append(.init(startedOn: nil, finishedOn: date)) }
                var journal = reading.journal ?? .init()
                journal.progress = .init(value: 100, unit: .percent)
                reading.journal = journal
            }
            reading.status = status
            if status == "read" || status == "currently-reading" {
                reading.upNextPosition = nil
                reading.upNextExcluded = true
            }
        }
    }

    private static func save(_ book: Book, context: ModelContext, repository: LibraryRepository?,
                             activity: [ReadingActivity] = [],
                             mutate: (inout StoryGraphReadingData) -> Void) throws {
        guard book.modelContext === context, !book.isRemovedFromLibrary else { throw ReadingActionError.unavailable }
        let original = book.storyGraphData
        let originalActivity = book.pendingActivityData
        var reading = UpNextQueue.metadata(for: book)
        mutate(&reading)
        let data = try JSONEncoder().encode(reading)
        // Leave headroom for PostgreSQL's spaced jsonb representation (128 KiB limit).
        guard data.count <= 96_000 else { throw ReadingActionError.full }
        book.storyGraphData = data
        // Intents commit in the same local save as the mutation and its outbox payload.
        repository?.appendActivity(activity, to: book)
        do {
            if let repository { try repository.save(book) }
            else { try context.save() }
        } catch {
            book.storyGraphData = original
            book.pendingActivityData = originalActivity
            throw error
        }
    }
}

enum ReadingActionError: LocalizedError {
    case invalidProgress, invalidText, invalidStatus, unavailable, full
    var errorDescription: String? {
        switch self {
        case .invalidProgress: return "Enter a whole page number, or a percentage from 0 to 100."
        case .invalidText: return "Enter between 1 and 4,000 characters."
        case .invalidStatus: return "Choose a reading status."
        case .unavailable: return "This book is no longer available in your archive."
        case .full: return "This book’s reading journal is full. Your new entry hasn’t been saved."
        }
    }
}
