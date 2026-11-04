#if DEBUG
import SwiftUI
import SwiftData

/// Deterministic, local-only Community for UI tests and screenshots. Never loads an
/// account or contacts Supabase; covers are the Open Library records the Discover
/// harness uses. Launch with `--community-ui-test`; add `--community-discover` to open
/// The Archive (Discover) instead, whose Friends tab reads the same fixture.
struct CommunityTestHarness: View {
    @State private var setup = try? CommunityHarnessSetup()

    var body: some View {
        if let setup {
            Group {
                if ProcessInfo.processInfo.arguments.contains("--archive-removal-ui-test") {
                    NavigationStack { ArchiveBooksView(repository: setup.library) }
                } else if ProcessInfo.processInfo.arguments.contains("--community-discover") {
                    DiscoverView(repository: setup.library)
                } else {
                    CommunityView()
                }
            }
            .modelContainer(setup.container)
            .environment(\.socialStore, setup.social)
            .environment(\.reviewLibraryRepository, setup.library)
            .textualScreenDefaults()
            .task { await setup.social.settings.refresh() }
        } else {
            Text("Harness unavailable")
        }
    }
}

@MainActor
private final class CommunityHarnessSetup {
    let container: ModelContainer
    let library: LibraryRepository
    let social: SocialStore

    init() throws {
        let schema = Schema([Book.self, Tag.self, LibrarySyncState.self, ReaderProfileDraft.self, ReaderReviewDraft.self,
                             DiscoveryCacheEntry.self, DiscoveryCollectionState.self, SocialSettingsState.self])
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let user = UUID(uuidString: "00000000-0000-0000-0000-0000000C0FFE")!
        library = LibraryRepository(userID: user, modelContext: container.mainContext, transport: CommunityHarnessLibrary(userID: user))
        social = SocialStore(userID: user, context: container.mainContext, transport: CommunityHarnessTransport())
        if ProcessInfo.processInfo.arguments.contains("--archive-removal-ui-test") {
            let book = Book(title: "Archive test book", author: "Test author", isbn: "", coverURL: "", googleBooksVolumeId: "storygraph:archive-test")
            try BookReadingActions.prepareArchiveStatus(.tbr, for: book)
            try library.add(book)
        }
    }
}

private struct CommunityHarnessLibrary: LibrarySyncTransport {
    let userID: UUID
    func authenticatedUserID() async throws -> UUID { userID }
    func synchronize(_ request: LibrarySyncRequest) async throws -> LibrarySyncResponse { throw URLError(.notConnectedToInternet) }
}

private actor CommunityHarnessTransport: SocialTransport {
    private struct Fixture { let id: String; let title: String; let author: String; let cover: Int }
    private static let books: [Fixture] = [
        .init(id: "OL41943074W", title: "Onyx Storm", author: "Rebecca Yarros", cover: 15233608),
        .init(id: "OL42487406W", title: "Fearless", author: "Lauren Roberts", cover: 15120652),
        .init(id: "OL42406707W", title: "Ward D", author: "Freida McFadden", cover: 15125127),
        .init(id: "OL42413995W", title: "Deep End", author: "Ali Hazelwood", cover: 14840882),
        .init(id: "OL42393184W", title: "King of Envy", author: "Ana Huang", cover: 15129532),
        .init(id: "OL43426400W", title: "Sunrise on the Reaping", author: "Suzanne Collins", cover: 14847912),
        .init(id: "OL42543873W", title: "Alchemised", author: "SenLinYu", cover: 15146435),
        .init(id: "OL42539351W", title: "Grumpy Darling", author: "Alexandra Moody", cover: 15101727),
        .init(id: "OL43113687W", title: "We Were Never Meant To Be", author: "Palle Vasu", cover: 15024571),
        .init(id: "OL42577236W", title: "Thank You for Leaving", author: "Rithvik Singh", cover: 14847895),
        .init(id: "OL42410140W", title: "What's Your Dream?", author: "Simon Squibb", cover: 14840729),
        .init(id: "OL43902203W", title: "How To Stop Overthinking Forever", author: "Rithvik Singh", cover: 15122359)
    ]
    private static func reader(_ n: Int, _ username: String, _ name: String) -> [String: Any] {
        ["user_id": String(format: "00000000-0000-0000-0000-%012d", n), "username": username, "first_name": name, "avatar_path": NSNull()]
    }
    private var relationships: [String: [String: Any]] = [
        "00000000-0000-0000-0000-000000000001": ["state": "friends", "request_id": "00000000-0000-0000-0000-0000000000a1"],
        "00000000-0000-0000-0000-000000000002": ["state": "friends", "request_id": "00000000-0000-0000-0000-0000000000a2"],
        "00000000-0000-0000-0000-000000000003": ["state": "friends", "request_id": "00000000-0000-0000-0000-0000000000a3"],
        "00000000-0000-0000-0000-000000000004": ["state": "incoming", "request_id": "00000000-0000-0000-0000-0000000000a4"],
        "00000000-0000-0000-0000-000000000005": ["state": "outgoing", "request_id": "00000000-0000-0000-0000-0000000000a5"]
    ]
    private let readers = [reader(1, "bea", "Bea"), reader(2, "cleo", "Cleo"), reader(3, "dot_com", "Dorothy"),
                           reader(4, "eli_reads", "Eli"), reader(5, "fern", "Fern"), reader(6, "beatrix", "Beatrix")]

    private func decode<T: Decodable>(_ value: Any) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value))
    }
    private func withRelationship(_ reader: [String: Any]) -> [String: Any] {
        var copy = reader
        copy["relationship"] = relationships[reader["user_id"] as! String] ?? ["state": "none"]
        return copy
    }
    private func book(_ fixture: Fixture, extra: [String: Any] = [:]) -> [String: Any] {
        ["book_id": UUID().uuidString, "title": fixture.title, "author": fixture.author, "isbn": NSNull(),
         "cover_url": "https://covers.openlibrary.org/b/id/\(fixture.cover)-L.jpg", "catalog_id": "openlibrary:\(fixture.id)"]
            .merging(extra) { _, new in new }
    }
    private static func stamp(hoursAgo: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date().addingTimeInterval(-hoursAgo * 3600))
    }

    func authenticatedUserID() async throws -> UUID { UUID(uuidString: "00000000-0000-0000-0000-0000000C0FFE")! }
    func settings() async throws -> SocialSettings {
        SocialSettings(activitySharing: true, sharingVersion: 1, booksReadVisible: true, genresVisible: true, rereadsVisible: true,
                       activityEnabled: true)
    }
    func updateSettings(userID: UUID, change: SocialSettingsChange) async throws -> SocialSettings {
        change.applied(to: try await settings())
    }
    func search(query: String, after: ReaderSearchPage.Cursor?, limit: Int) async throws -> ReaderSearchPage {
        let q = query.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        let matches = readers.filter { ($0["username"] as! String).hasPrefix(q) || ($0["first_name"] as! String).lowercased().hasPrefix(q) }
        return try decode(["results": matches.map(withRelationship), "next": NSNull()] as [String: Any])
    }
    func friends(after: String?, limit: Int) async throws -> FriendsPage {
        let all = readers.map(withRelationship)
        func state(_ value: String) -> [[String: Any]] {
            all.filter { ($0["relationship"] as? [String: Any])?["state"] as? String == value }
        }
        return try decode(["friends": state("friends"), "incoming": state("incoming"), "outgoing": state("outgoing"),
                           "next": NSNull()] as [String: Any])
    }
    func profileFriends(username: String, after: String?, limit: Int) async throws -> ProfileFriendsPage {
        let visible = [readers[1], readers[2], readers[5]].map(withRelationship)
        return try decode(["friends": visible, "next": NSNull()] as [String: Any])
    }
    func publishProfileGenres(userID: UUID, entries: [ProfileGenreEntry]) async throws {}
    func genreBooks(username: String, genre: String, after: ProfileBooksPage.Cursor?, limit: Int) async throws -> ProfileBooksPage {
        try await books(username: username, list: .read, after: after, limit: limit)
    }
    func updateFriendship(userID: UUID, operationID: UUID, action: FriendshipAction, target: UUID,
                          requestID: UUID?) async throws -> FriendshipResult {
        try await Task.sleep(for: .milliseconds(1500))
        let key = target.uuidString.lowercased()
        let next: String
        switch action {
        case .send: next = "outgoing"
        case .accept: next = "friends"
        case .decline, .cancel, .remove: next = "none"
        }
        relationships[key] = ["state": next, "request_id": UUID().uuidString]
        return try decode(["outcome": action.rawValue, "relationship": relationships[key]!] as [String: Any])
    }
    func profile(username: String) async throws -> VisitorProfile? {
        guard let reader = readers.first(where: { $0["username"] as? String == username }) else { return nil }
        let private_ = username == "cleo"
        let favorites = Self.books.prefix(7).map { fixture -> [String: Any] in
            ["id": UUID().uuidString, "title": fixture.title, "author": fixture.author, "isbn": "",
             "coverURL": "https://covers.openlibrary.org/b/id/\(fixture.cover)-L.jpg", "catalogID": "openlibrary:\(fixture.id)"]
        }
        let breakdown: [[String: Any]] = [["name": "Fantasy", "books": 31, "reads": 36], ["name": "Romance", "books": 24, "reads": 26],
            ["name": "Thriller", "books": 12, "reads": 12], ["name": "Literary", "books": 8, "reads": 8],
            ["name": "Memoir", "books": 3, "reads": 3], ["name": "Unclassified", "books": 2, "reads": 2]]
        let hidden: [String: Any] = ["visible": false]
        let genres: [String: Any] = ["visible": true, "count": 5, "breakdown": breakdown]
        let rereads: [String: Any] = ["visible": true, "count": 7, "books": 5]
        let card: [String: Any] = [
            "books_read": ["visible": true, "count": private_ ? 80 : 87, "books": 80] as [String: Any],
            "genres": private_ ? hidden : genres,
            "rereads": private_ ? hidden : rereads
        ]
        return try decode(reader.merging([
            "is_owner": false, "member_since": "2026-01-01T00:00:00+00:00",
            "sentence": "under the covers with a light on, falling for someone with a terrible secret.",
            "favorites": favorites, "card": card, "relationship": relationships[reader["user_id"] as! String] ?? ["state": "none"]
        ]) { _, new in new })
    }
    func books(username: String, list: ProfileBookList, after: ProfileBooksPage.Cursor?, limit: Int) async throws -> ProfileBooksPage {
        let total = list == .read ? 80 : 5
        let start = after.flatMap { Int($0.title.split(separator: "|").last ?? "") } ?? 0
        let rows = (start..<min(total, start + limit)).map { n -> [String: Any] in
            let fixture = Self.books[n % Self.books.count]
            // Later copies are numbered so a UI test can tell a second page arrived.
            let title = n < Self.books.count ? fixture.title : "\(fixture.title) (\(n + 1))"
            var row: [String: Any] = ["entry_id": UUID().uuidString, "title": title, "author": fixture.author, "isbn": NSNull(),
                       "cover_url": "https://covers.openlibrary.org/b/id/\(fixture.cover)-L.jpg",
                       "catalog_id": "openlibrary:\(fixture.id)", "source": list == .read ? "books_read" : "rereads"]
            if list == .rereads { row["times_read"] = 2 + n % 2 }
            return row
        }
        let end = start + rows.count
        return try decode(["books": rows, "total": after == nil ? total : NSNull(),
            "next": end < total ? ["title": "page|\(end)", "id": UUID().uuidString] : NSNull()] as [String: Any])
    }
    func feed(cutoff: String?, before: FeedPage.Cursor?, limit: Int) async throws -> FeedPage {
        guard before == nil else { return try decode(["cutoff": Self.stamp(hoursAgo: 0), "events": [], "next": NSNull()] as [String: Any]) }
        let bea = withRelationship(readers[0]), cleo = withRelationship(readers[1]), dot = withRelationship(readers[2])
        let onyx = book(Self.books[0]), fearless = book(Self.books[1]), ward = book(Self.books[2])
        let deep = book(Self.books[3]), envy = book(Self.books[4])
        func event(_ kind: String, _ actor: [String: Any], _ book: [String: Any], hoursAgo: Double, read: Int? = nil,
                   quote: [String: Any]? = nil, review: [String: Any]? = nil) -> [String: Any] {
            ["id": UUID().uuidString, "kind": kind, "published_at": Self.stamp(hoursAgo: hoursAgo),
             "occurred_at": Self.stamp(hoursAgo: hoursAgo), "read_number": read.map { $0 as Any } ?? NSNull(),
             "actor": actor, "book": book, "quote": quote ?? NSNull(), "review": review ?? NSNull(), "source": kind]
        }
        let events: [[String: Any]] = [
            event("review", bea, onyx, hoursAgo: 2, review: ["rating": 18, "body": "I stayed up far too late for the last hundred pages. Worth every yawn.", "spoilers": false]),
            event("finished", bea, onyx, hoursAgo: 2.2, read: 1),
            event("quote", cleo, fearless, hoursAgo: 5, quote: ["text": "Fear is a funny thing; it only follows you if you let it lead.", "page": 112]),
            event("quote", cleo, fearless, hoursAgo: 5.5, quote: ["text": "Some promises are only kept by breaking others.", "page": NSNull()]),
            event("started", dot, ward, hoursAgo: 26, read: 1),
            event("shelf", bea, deep, hoursAgo: 49),
            event("finished", cleo, envy, hoursAgo: 72, read: 2)
        ]
        return try decode(["cutoff": Self.stamp(hoursAgo: 0), "events": events, "next": NSNull()] as [String: Any])
    }
    func discovery(snapshot: String?, after: FriendDiscoveryPage.Cursor?, limit: Int) async throws -> FriendDiscoveryPage {
        let rows = Self.books.enumerated().map { index, fixture in
            book(fixture, extra: ["sources": index % 3 == 0 ? ["review", "shelf"] : ["finished"], "score": 10 - index])
        }
        return try decode(["snapshot": Self.stamp(hoursAgo: 0), "has_friends": true, "books": rows, "next": NSNull()] as [String: Any])
    }
}
#endif
