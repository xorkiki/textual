import Foundation
import SwiftData

/// The public projection is deliberately separate from private reading/import data.
struct ReaderCardStats: Codable, Equatable, Sendable {
    var reads = 0
    var genres = 0
    var rereads = 0
}

struct ReaderFavorite: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let author: String
    let isbn: String
    var coverURL: String
    var catalogID: String?

    init(book: Book) {
        id = book.id; title = book.title; author = book.author; isbn = book.isbn
        let cached = Self.metadata(book)
        coverURL = Self.cover(book)
        catalogID = cached?.id ?? book.googleBooksVolumeId
    }

    /// A detached catalog-only book cannot reveal the owner's notes or reading history.
    func detailBook() -> Book {
        Book(id: id, title: title, author: author, isbn: isbn,
             coverURL: coverURL, googleBooksVolumeId: catalogID)
    }

    func matches(_ book: Book) -> Bool {
        id == book.id || (catalogID != nil && (catalogID == book.googleBooksVolumeId || catalogID == Self.metadata(book)?.id))
            || (!isbn.isEmpty && isbn == book.isbn)
    }

    static func cover(_ book: Book) -> String {
        if let resolved = book.resolvedCoverURL, !resolved.isEmpty { return resolved }
        let cached = metadata(book)?.volumeInfo?.imageLinks
        return BookCatalogService.secureImageURL(book.coverURL.isEmpty ? (cached?.thumbnail ?? cached?.smallThumbnail) : book.coverURL)
    }

    func refreshed(from books: [Book]) -> Self {
        guard let book = books.first(where: { matches($0) }) else { return self }
        var result = self
        let url = Self.cover(book)
        if !url.isEmpty { result.coverURL = url }
        if let id = Self.metadata(book)?.id { result.catalogID = id }
        return result
    }

    private static func metadata(_ book: Book) -> BookCatalogService.BookItem? {
        book.cachedCatalogMetadata.flatMap { try? JSONDecoder().decode(BookCatalogService.BookItem.self, from: $0) }
    }
}

struct ReaderPublicContent: Codable, Equatable, Sendable {
    var stats: ReaderCardStats
    var sentence: String
    var favorites: [ReaderFavorite]
    var avatarPath: String? = nil
}

struct PublicReaderProfile: Codable, Equatable, Identifiable, Sendable {
    let username: String
    let firstName: String
    let memberSince: String
    let revision: Int
    let content: ReaderPublicContent
    var id: String { username }
}

@Model
final class ReaderProfileDraft {
    @Attribute(.unique) var userID: UUID
    var contentData: Data
    var serverRevision: Int = 0
    var needsUpload: Bool = true
    var hasLoadedRemote: Bool = false
    @Attribute(.externalStorage) var avatarData: Data? = nil
    var avatarDataPath: String? = nil
    var avatarNeedsUpload: Bool = false

    init(userID: UUID, content: ReaderPublicContent) throws {
        self.userID = userID
        contentData = try JSONEncoder().encode(content)
    }

    var content: ReaderPublicContent? { try? JSONDecoder().decode(ReaderPublicContent.self, from: contentData) }
    var matchingAvatarData: Data? { avatarDataPath == content?.avatarPath ? avatarData : nil }
}

enum ReaderShelf {
    static let limit = 15

    static func adding(_ book: Book, to favorites: [ReaderFavorite]) -> [ReaderFavorite] {
        guard favorites.count < limit, !favorites.contains(where: { $0.matches(book) }) else { return favorites }
        return favorites + [ReaderFavorite(book: book)]
    }

    static func moving(_ id: UUID, to target: UUID, in favorites: [ReaderFavorite]) -> [ReaderFavorite] {
        guard let from = favorites.firstIndex(where: { $0.id == id }),
              let to = favorites.firstIndex(where: { $0.id == target }), from != to else { return favorites }
        var result = favorites
        result.insert(result.remove(at: from), at: to)
        return result
    }
}

/// Deterministic, on-device copy: stable until the actual reading evidence changes.
/// Genres, moods, and book pace describe books, never a person's sensitive traits.
enum ReaderPersonality {
    struct Evidence: Sendable {
        var completedReads: Int
        var genres: Set<String>
        var moods: [String]
        var pace: String
    }

    @MainActor static func evidence(_ books: [Book]) -> [Evidence] {
        books.filter { !$0.isRemovedFromLibrary }.compactMap { book in
            guard let reading = book.importedReading else { return nil }
            let count = ReadingStatsFilter.completedCount(reading)
            guard count > 0 else { return nil }
            return Evidence(completedReads: count,
                genres: StatsMetadataCache.genres(book),
                moods: reading.moods, pace: reading.pace)
        }
    }

    static func summarize(_ evidence: [Evidence], favorites: [ReaderFavorite]) -> ReaderPublicContent {
        let completed = evidence.filter { $0.completedReads > 0 }
        let stats = ReaderCardStats(reads: completed.reduce(0) { $0 + $1.completedReads },
            genres: Set(completed.flatMap(\.genres)).count,
            rereads: completed.reduce(0) { $0 + max(0, $1.completedReads - 1) })
        return ReaderPublicContent(stats: stats, sentence: sentence(completed), favorites: Array(favorites.prefix(ReaderShelf.limit)))
    }

    static func sentence(_ evidence: [Evidence]) -> String {
        let completed = evidence.filter { $0.completedReads > 0 }
        // Rereading one book many times is not broad enough evidence to assign a type.
        guard completed.count >= 3 else { return "new to the library. judgment pending, fondly." }
        guard completed.filter({ !$0.genres.isEmpty || !$0.moods.isEmpty || ["fast", "medium", "slow"].contains(normalize($0.pace)) }).count >= 3 else {
            return "the reading is on record. the library is still getting a feel for the plot."
        }
        var genres: [String: Int] = [:], moods: [String: Int] = [:], paces: [String: Int] = [:]
        for entry in completed {
            for genre in entry.genres { genres[genre, default: 0] += entry.completedReads }
            for mood in Set(entry.moods.map(normalize)) { moods[mood, default: 0] += entry.completedReads }
            paces[normalize(entry.pace), default: 0] += entry.completedReads
        }
        func ranked(_ values: [String: Int]) -> [String] {
            values.filter { !$0.key.isEmpty && $0.value > 0 }.sorted {
                $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
            }.map(\.key)
        }
        let topGenres = Set(ranked(genres).prefix(3))
        let topMoods = Set(ranked(moods).prefix(2))
        let topGenre = ranked(genres).first
        let topPace = ranked(paces).first
        let tense = !topGenres.isDisjoint(with: ["Thriller", "Mystery", "Horror", "Crime"])
            || !topMoods.isDisjoint(with: ["tense", "mysterious", "dark"])
        if topGenres.contains("Fantasy") && topGenres.contains("Romance") {
            return tense ? "under the covers with a light on, falling for someone with a terrible secret."
                : "somewhere between a love confession and a portal, ignoring the real world beautifully."
        }
        if topGenres.contains("Romance") && tense {
            return "here for the yearning, staying to find out who did it."
        }
        if tense { return "under the covers with a light on, trusting absolutely no one in chapter twelve." }
        if topGenre == "Fantasy" { return "a little unavailable; there’s another realm to be in." }
        if topGenre == "Romance" { return "pretending to read for the plot, waiting for the hand to brush the hand." }
        if topGenre == "Poetry" { return "carrying one devastating line around like it’s a perfectly normal thing to do." }
        if topGenre == "Science fiction" { return "mentally elsewhere, possibly in a century that hasn’t happened yet." }
        if topGenre == "Memoir" || topGenre == "Biography" {
            return "just one more chapter in somebody else’s very complicated life."
        }
        if topGenre == "History" || topGenre == "Historical" { return "unavailable at present; emotionally invested in another century." }
        if topGenre == "Art" { return "here for the beautiful things and the footnotes behind them." }
        if topGenre == "Philosophy" || topGenre == "Psychology" || topGenre == "Essays" {
            return "came for a quiet read, left with several inconvenient questions."
        }
        if topMoods.contains("emotional") || topMoods.contains("sad") {
            return "calling it a quiet evening, letting a book rearrange all their feelings."
        }
        if topMoods.contains("reflective") { return "reading a little, staring out the window a lot; it’s all part of the process." }
        if topMoods.contains("adventurous") { return "perfectly comfortable here, emotionally halfway across the map." }
        if topMoods.contains("funny") { return "laughing into a book in public, offering no explanation." }
        if topPace == "fast" { return "drawn to plots with no brakes; the bookmark is mostly decorative." }
        if topPace == "slow" { return "partial to a slow burn, including the paragraph everyone else skimmed." }
        if completed.reduce(0, { $0 + max(0, $1.completedReads - 1) }) >= 3 {
            return "back with an old favorite, as if the ending might miss them." }
        return genres.isEmpty && moods.isEmpty
            ? "the reading is on record. the library is still getting a feel for the plot."
            : "a wandering eye for the shelves and a very loose definition of one more book."
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
