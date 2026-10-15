import Foundation
import SwiftData

// MARK: - Readers and relationships

/// The viewer's own relationship with one other reader, as the server reports it.
struct ReaderRelationship: Codable, Equatable, Hashable, Sendable {
    enum State: String, Codable, Sendable { case none, outgoing, incoming, friends }
    let state: State
    let requestID: UUID?

    init(state: State, requestID: UUID? = nil) {
        self.state = state
        self.requestID = requestID
    }

    enum CodingKeys: String, CodingKey {
        case state
        case requestID = "request_id"
    }

}

/// Public identity only: username, first name, published photo path.
struct SocialReader: Codable, Equatable, Hashable, Identifiable, Sendable {
    let userID: UUID
    let username: String
    let firstName: String
    let avatarPath: String?
    var relationship: ReaderRelationship?
    var id: UUID { userID }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id", username, relationship
        case firstName = "first_name", avatarPath = "avatar_path"
    }
}

struct ReaderSearchPage: Decodable, Sendable {
    struct Cursor: Codable, Equatable, Sendable {
        let rank: Int
        let username: String
    }
    let results: [SocialReader]
    let next: Cursor?
}

struct FriendsPage: Decodable, Sendable {
    let friends: [SocialReader]
    let incoming: [SocialReader]
    let outgoing: [SocialReader]
    let next: String?
}

struct FriendshipResult: Decodable, Sendable {
    let outcome: String
    let relationship: ReaderRelationship
}

enum FriendshipAction: String, Sendable { case send, accept, decline, cancel, remove }

// MARK: - Privacy settings

struct SocialSettings: Codable, Equatable, Sendable {
    var activitySharing: Bool
    var sharingVersion: Int64
    var booksReadVisible: Bool
    var genresVisible: Bool
    var rereadsVisible: Bool
    /// True once the database verifies activity intents (migration 012). Until then
    /// the app sends none, so library sync keeps working on an older database.
    var activityEnabled: Bool? = nil
}

/// Keys accepted by `textual_update_social_settings`.
struct SocialSettingsChange: Codable, Equatable, Sendable {
    var activitySharing: Bool?
    var booksReadVisible: Bool?
    var genresVisible: Bool?
    var rereadsVisible: Bool?

    func merged(over other: SocialSettingsChange?) -> SocialSettingsChange {
        SocialSettingsChange(activitySharing: activitySharing ?? other?.activitySharing,
                             booksReadVisible: booksReadVisible ?? other?.booksReadVisible,
                             genresVisible: genresVisible ?? other?.genresVisible,
                             rereadsVisible: rereadsVisible ?? other?.rereadsVisible)
    }

    func applied(to settings: SocialSettings) -> SocialSettings {
        var result = settings
        if let activitySharing { result.activitySharing = activitySharing }
        if let booksReadVisible { result.booksReadVisible = booksReadVisible }
        if let genresVisible { result.genresVisible = genresVisible }
        if let rereadsVisible { result.rereadsVisible = rereadsVisible }
        return result
    }
}

/// The owner's last known server settings and any change still waiting to upload.
/// Lives in the account store, so it is partitioned by account like the archive.
@Model
final class SocialSettingsState {
    @Attribute(.unique) var userID: UUID
    var serverData: Data?
    var pendingData: Data?
    var loadedAt: Date?

    init(userID: UUID) { self.userID = userID }

    var server: SocialSettings? { serverData.flatMap { try? JSONDecoder().decode(SocialSettings.self, from: $0) } }
    var pending: SocialSettingsChange? { pendingData.flatMap { try? JSONDecoder().decode(SocialSettingsChange.self, from: $0) } }
}

// MARK: - Activity intents

/// One explicit reader action, frozen into the existing outbox payload with the
/// mutation that performed it. The server publishes it only if it can verify the
/// transition and the stamped sharing version is still current.
struct SocialActivityIntent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case started, finished, quote, review, shelf }
    let id: UUID
    let kind: Kind
    let shared: Bool
    let sharingVersion: Int64
    let occurredAt: String
    var quoteID: UUID? = nil
    var favoriteID: UUID? = nil

    enum CodingKeys: String, CodingKey {
        case id, kind, shared
        case sharingVersion = "sharing_version", occurredAt = "occurred_at"
        case quoteID = "quote_id", favoriteID = "favorite_id"
    }

    static func decodeList(_ data: Data?) -> [SocialActivityIntent] {
        data.flatMap { try? JSONDecoder().decode([SocialActivityIntent].self, from: $0) } ?? []
    }

    static func encodeList(_ intents: [SocialActivityIntent]) -> Data? {
        intents.isEmpty ? nil : try? JSONEncoder().encode(Array(intents.suffix(maximumPending)))
    }

    /// Matches the server's per-change bound; older intents are dropped, never sent twice.
    static let maximumPending = 20
}

/// Present only when sharing is known to be on: settings were loaded from the
/// server and no settings change is waiting to upload. Otherwise no intent exists.
struct SocialActivityStamp: Equatable, Sendable {
    let sharingVersion: Int64

    func intent(_ kind: SocialActivityIntent.Kind, quoteID: UUID? = nil, favoriteID: UUID? = nil,
                now: Date = Date()) -> SocialActivityIntent {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return SocialActivityIntent(id: UUID(), kind: kind, shared: true, sharingVersion: sharingVersion,
                                    occurredAt: formatter.string(from: now), quoteID: quoteID, favoriteID: favoriteID)
    }
}

// MARK: - Visitor library cards

struct ReaderGenreShare: Codable, Equatable, Hashable, Sendable {
    let name: String
    let books: Int
    /// Absent for visitors when the owner hides rereads.
    var reads: Int?
}

struct PublicCardDetails: Decodable, Equatable, Sendable {
    struct Stat: Decodable, Equatable, Sendable {
        let visible: Bool
        let count: Int?
        let books: Int?
    }
    struct Genres: Decodable, Equatable, Sendable {
        let visible: Bool
        let count: Int?
        let breakdown: [ReaderGenreShare]?
    }
    let booksRead: Stat
    let genres: Genres
    let rereads: Stat

    enum CodingKeys: String, CodingKey {
        case genres, rereads
        case booksRead = "books_read"
    }
}

struct VisitorProfile: Decodable, Equatable, Identifiable, Sendable {
    let userID: UUID
    let username: String
    let firstName: String
    let avatarPath: String?
    let isOwner: Bool
    let sentence: String?
    let favorites: [ReaderFavorite]
    let card: PublicCardDetails?
    let relationship: ReaderRelationship?
    var id: String { username }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id", username, sentence, favorites, card, relationship
        case firstName = "first_name", avatarPath = "avatar_path", isOwner = "is_owner"
    }

    var reader: SocialReader {
        SocialReader(userID: userID, username: username, firstName: firstName, avatarPath: avatarPath,
                     relationship: relationship)
    }
}

/// One permitted book in a visitor's Books Read or Rereads list. Display metadata only.
struct ProfileBook: Decodable, Hashable, Identifiable, Sendable {
    let entryID: UUID
    let title: String
    let author: String
    let isbn: String?
    let coverURL: String?
    let catalogID: String
    /// Why this book may be shown: "books_read" or "rereads".
    let source: String
    let timesRead: Int?
    var id: UUID { entryID }

    enum CodingKeys: String, CodingKey {
        case title, author, isbn, source
        case entryID = "entry_id", coverURL = "cover_url", catalogID = "catalog_id", timesRead = "times_read"
    }
}

struct ProfileBooksPage: Decodable, Sendable {
    struct Cursor: Codable, Equatable, Sendable {
        let title: String
        let id: UUID
    }
    let books: [ProfileBook]
    let total: Int?
    let next: Cursor?
}

enum ProfileBookList: String, Sendable { case read, rereads }

// MARK: - Feed

struct FeedBook: Decodable, Hashable, Sendable {
    let bookID: UUID
    let title: String?
    let author: String?
    let isbn: String?
    let coverURL: String?
    let catalogID: String?

    enum CodingKeys: String, CodingKey {
        case title, author, isbn
        case bookID = "book_id", coverURL = "cover_url", catalogID = "catalog_id"
    }
}

struct FeedEvent: Decodable, Equatable, Identifiable, Sendable {
    enum Kind: String, Decodable, Sendable { case started, finished, quote, review, shelf }
    struct Quote: Decodable, Equatable, Sendable {
        let text: String
        let page: Int?
    }
    struct Review: Decodable, Equatable, Sendable {
        let rating: Int?
        let body: String?
        let spoilers: Bool?
    }
    let id: UUID
    let kind: Kind
    /// Server timestamps stay exact strings so they round-trip as cursors.
    let publishedAt: String
    let occurredAt: String
    /// Present only when the reader shows Rereads on their card.
    let readNumber: Int?
    let actor: SocialReader
    let book: FeedBook
    let quote: Quote?
    let review: Review?
    /// Opaque per-read identity, so separate reads never merge without revealing a count.
    var readKey: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, kind, actor, book, quote, review
        case publishedAt = "published_at", occurredAt = "occurred_at", readNumber = "read_number", readKey = "read_key"
    }

    var readIdentity: String? { readKey ?? readNumber.map(String.init) }

    var occurredDate: Date? { DiscoveryDate.parse(occurredAt) }
    var publishedDate: Date? { DiscoveryDate.parse(publishedAt) }
}

struct FeedPage: Decodable, Sendable {
    struct Cursor: Codable, Equatable, Sendable {
        let publishedAt: String
        let id: UUID
        enum CodingKeys: String, CodingKey {
            case id
            case publishedAt = "published_at"
        }
    }
    let cutoff: String
    let events: [FeedEvent]
    let next: Cursor?
}

/// Related actions by one reader on one book, shown as one card. Raw events are kept.
struct FeedGroup: Equatable, Identifiable, Sendable {
    let id: UUID
    var events: [FeedEvent]
    var actor: SocialReader { events[0].actor }
    var book: FeedBook { events[0].book }
}

/// Groups in feed order. An event only joins a group created by earlier (newer)
/// events, so appending a page never reorders cards already on screen, and the
/// result is the same whether events arrive in one page or many.
enum FeedGrouping {
    /// A finish, its review, and quotes from the same sitting read as one update.
    static let window: TimeInterval = 12 * 3600

    static func group(_ events: [FeedEvent]) -> [FeedGroup] {
        append(events, to: [])
    }

    static func append(_ events: [FeedEvent], to existing: [FeedGroup]) -> [FeedGroup] {
        var groups = existing
        var seen = Set(existing.flatMap { $0.events.map(\.id) })
        for event in events where seen.insert(event.id).inserted {
            if let index = groups.lastIndex(where: { accepts($0, event) }) {
                groups[index].events.append(event)
            } else {
                groups.append(FeedGroup(id: event.id, events: [event]))
            }
        }
        return groups
    }

    private static func accepts(_ group: FeedGroup, _ event: FeedEvent) -> Bool {
        guard group.actor.userID == event.actor.userID, group.book.bookID == event.book.bookID,
              let newest = group.events.first?.publishedDate, let date = event.publishedDate,
              newest.timeIntervalSince(date) <= window else { return false }
        switch event.kind {
        // A start and finish join only when they belong to the same read; quotes stay individual.
        case .started, .finished:
            return !group.events.contains { $0.kind == event.kind }
                && group.events.allSatisfy { ![.started, .finished].contains($0.kind) || $0.readIdentity == event.readIdentity }
        case .review, .shelf:
            return !group.events.contains { $0.kind == event.kind }
        case .quote:
            return true
        }
    }
}

// MARK: - Discover → Friends

struct FriendDiscoveryPage: Decodable, Sendable {
    struct Row: Decodable, Sendable {
        let bookID: UUID
        let title: String?
        let author: String?
        let isbn: String?
        let coverURL: String?
        let catalogID: String?
        let sources: [String]

        enum CodingKeys: String, CodingKey {
            case title, author, isbn, sources
            case bookID = "book_id", coverURL = "cover_url", catalogID = "catalog_id"
        }

        var item: DiscoverItem? {
            guard let catalogID, !catalogID.isEmpty,
                  let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
            let isbns = isbn.map { [$0] }?.filter { !$0.isEmpty } ?? []
            return DiscoverItem(catalogID: catalogID, title: title, author: author ?? "", isbns: isbns,
                                coverURL: coverURL ?? "", aspect: DiscoverItem.fallbackAspect, firstPublishedYear: nil,
                                subjects: [], facet: nil, sources: sources, popularity: 0, expiresAt: nil)
        }
    }
    struct Cursor: Codable, Equatable, Sendable {
        /// Exact decimal, so the keyset comparison round-trips.
        let score: Decimal
        let bookID: UUID
        enum CodingKeys: String, CodingKey {
            case score
            case bookID = "book_id"
        }
    }
    let snapshot: String
    let hasFriends: Bool
    let books: [Row]
    let next: Cursor?

    enum CodingKeys: String, CodingKey {
        case snapshot, books, next
        case hasFriends = "has_friends"
    }
}

// MARK: - Shared presentation helpers

extension ProfileBook {
    /// A detached catalog-only book: opening it never creates an archive entry.
    func detailBook() -> Book {
        Book(title: title, author: author, isbn: isbn ?? "", coverURL: coverURL ?? "", googleBooksVolumeId: catalogID)
    }
}

extension FeedBook {
    func detailBook() -> Book {
        Book(title: title ?? "Untitled", author: author ?? "", isbn: isbn ?? "", coverURL: coverURL ?? "",
             googleBooksVolumeId: catalogID)
    }
}

enum SocialError: LocalizedError, Equatable {
    case rateLimited, notFound, forbidden, accountChanged, unavailable

    var errorDescription: String? {
        switch self {
        case .rateLimited: return "That’s a lot at once. Try again in a moment."
        case .notFound: return "That reader couldn’t be found."
        case .forbidden: return "This isn’t shared with you."
        case .accountChanged: return "Your account changed. Reopen Textual to continue."
        case .unavailable: return "Community couldn’t load right now. Try again."
        }
    }
}
