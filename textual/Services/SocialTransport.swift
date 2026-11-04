import Foundation
import Supabase
import os

protocol SocialTransport: Sendable {
    func authenticatedUserID() async throws -> UUID
    func settings() async throws -> SocialSettings
    func updateSettings(userID: UUID, change: SocialSettingsChange) async throws -> SocialSettings
    func search(query: String, after: ReaderSearchPage.Cursor?, limit: Int) async throws -> ReaderSearchPage
    func friends(after: String?, limit: Int) async throws -> FriendsPage
    func profileFriends(username: String, after: String?, limit: Int) async throws -> ProfileFriendsPage
    func publishProfileGenres(userID: UUID, entries: [ProfileGenreEntry]) async throws
    func genreBooks(username: String, genre: String, after: ProfileBooksPage.Cursor?, limit: Int) async throws -> ProfileBooksPage
    func updateFriendship(userID: UUID, operationID: UUID, action: FriendshipAction, target: UUID,
                          requestID: UUID?) async throws -> FriendshipResult
    func profile(username: String) async throws -> VisitorProfile?
    func books(username: String, list: ProfileBookList, after: ProfileBooksPage.Cursor?, limit: Int) async throws -> ProfileBooksPage
    func feed(cutoff: String?, before: FeedPage.Cursor?, limit: Int) async throws -> FeedPage
    func discovery(snapshot: String?, after: FriendDiscoveryPage.Cursor?, limit: Int) async throws -> FriendDiscoveryPage
}

/// Network work and decoding stay off the main actor; only Sendable values cross back.
/// Logs record the RPC name, duration, and error code only: never parameters,
/// tokens, quote/review text, or profile data.
actor SupabaseSocialTransport: SocialTransport {
    private let client: SupabaseClient
    private let log = Logger(subsystem: "kiki.textual", category: "Social")

    init(client: SupabaseClient) { self.client = client }

    func authenticatedUserID() async throws -> UUID {
        try await client.auth.session.user.id
    }

    func settings() async throws -> SocialSettings {
        try await call("textual_social_settings", EmptyParameters())
    }

    func updateSettings(userID: UUID, change: SocialSettingsChange) async throws -> SocialSettings {
        guard try await authenticatedUserID() == userID else { throw SocialError.accountChanged }
        struct Parameters: Encodable { let p_expected_user_id: UUID; let p_settings: SocialSettingsChange }
        return try await call("textual_update_social_settings", Parameters(p_expected_user_id: userID, p_settings: change))
    }

    func search(query: String, after: ReaderSearchPage.Cursor?, limit: Int) async throws -> ReaderSearchPage {
        struct Parameters: Encodable {
            let p_query: String; let p_after_rank: Int?; let p_after_username: String?; let p_limit: Int
        }
        return try await call("textual_search_readers", Parameters(p_query: query, p_after_rank: after?.rank,
                                                                   p_after_username: after?.username, p_limit: limit))
    }

    func friends(after: String?, limit: Int) async throws -> FriendsPage {
        struct Parameters: Encodable { let p_after_username: String?; let p_limit: Int }
        return try await call("textual_list_friends", Parameters(p_after_username: after, p_limit: limit))
    }

    func profileFriends(username: String, after: String?, limit: Int) async throws -> ProfileFriendsPage {
        struct Parameters: Encodable { let p_username: String; let p_after_username: String?; let p_limit: Int }
        return try await call("textual_read_profile_friends", Parameters(p_username: username,
            p_after_username: after, p_limit: limit))
    }

    func publishProfileGenres(userID: UUID, entries: [ProfileGenreEntry]) async throws {
        guard try await authenticatedUserID() == userID else { throw SocialError.accountChanged }
        struct Parameters: Encodable { let p_expected_user_id: UUID; let p_entries: [ProfileGenreEntry] }
        let _: Bool = try await call("textual_publish_profile_genres",
            Parameters(p_expected_user_id: userID, p_entries: entries))
    }

    func genreBooks(username: String, genre: String, after: ProfileBooksPage.Cursor?, limit: Int) async throws -> ProfileBooksPage {
        struct Parameters: Encodable {
            let p_username: String; let p_genre: String; let p_after_title: String?; let p_after_id: UUID?; let p_limit: Int
        }
        return try await call("textual_read_profile_genre_books", Parameters(p_username: username,
            p_genre: genre, p_after_title: after?.title, p_after_id: after?.id, p_limit: limit))
    }

    func updateFriendship(userID: UUID, operationID: UUID, action: FriendshipAction, target: UUID,
                          requestID: UUID?) async throws -> FriendshipResult {
        guard try await authenticatedUserID() == userID else { throw SocialError.accountChanged }
        struct Parameters: Encodable {
            let p_expected_user_id: UUID; let p_operation_id: UUID; let p_action: String
            let p_target: UUID; let p_request_id: UUID?
        }
        return try await call("textual_update_friendship", Parameters(p_expected_user_id: userID, p_operation_id: operationID,
            p_action: action.rawValue, p_target: target, p_request_id: requestID))
    }

    func profile(username: String) async throws -> VisitorProfile? {
        struct Parameters: Encodable { let p_username: String }
        return try await call("textual_read_public_profile", Parameters(p_username: username))
    }

    func books(username: String, list: ProfileBookList, after: ProfileBooksPage.Cursor?, limit: Int) async throws -> ProfileBooksPage {
        struct Parameters: Encodable {
            let p_username: String; let p_list: String; let p_after_title: String?; let p_after_id: UUID?; let p_limit: Int
        }
        return try await call("textual_read_profile_books", Parameters(p_username: username, p_list: list.rawValue,
            p_after_title: after?.title, p_after_id: after?.id, p_limit: limit))
    }

    func feed(cutoff: String?, before: FeedPage.Cursor?, limit: Int) async throws -> FeedPage {
        struct Parameters: Encodable {
            let p_cutoff: String?; let p_before_published_at: String?; let p_before_id: UUID?; let p_limit: Int
        }
        return try await call("textual_read_feed", Parameters(p_cutoff: cutoff, p_before_published_at: before?.publishedAt,
                                                              p_before_id: before?.id, p_limit: limit))
    }

    func discovery(snapshot: String?, after: FriendDiscoveryPage.Cursor?, limit: Int) async throws -> FriendDiscoveryPage {
        struct Parameters: Encodable {
            let p_snapshot: String?; let p_after_score: Decimal?; let p_after_book: UUID?; let p_limit: Int
        }
        return try await call("textual_read_friend_discovery", Parameters(p_snapshot: snapshot, p_after_score: after?.score,
                                                                          p_after_book: after?.bookID, p_limit: limit))
    }

    private struct EmptyParameters: Encodable {}

    private func call<Parameters: Encodable & Sendable, Value: Decodable>(_ name: String, _ parameters: Parameters) async throws -> Value {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let response = try await client.rpc(name, params: parameters).execute()
            let value = try JSONDecoder().decode(Value.self, from: response.data)
            log.debug("\(name, privacy: .public) ok \(Self.milliseconds(clock.now - start), privacy: .public) ms")
            return value
        } catch {
            let mapped = Self.map(error)
            log.error("\(name, privacy: .public) failed after \(Self.milliseconds(clock.now - start), privacy: .public) ms code=\(Self.code(error), privacy: .public)")
            throw mapped
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
    }

    private static func code(_ error: Error) -> String {
        if let error = error as? PostgrestError { return error.code ?? "postgrest" }
        if let error = error as? URLError { return "url-\(error.code.rawValue)" }
        if error is DecodingError { return "decoding" }
        if error is CancellationError { return "cancelled" }
        return "other"
    }

    static func map(_ error: Error) -> Error {
        guard let error = error as? PostgrestError else { return error }
        switch error.code {
        case "PT429": return SocialError.rateLimited
        case "P0002": return SocialError.notFound
        case "42501": return SocialError.forbidden
        default: return SocialError.unavailable
        }
    }
}
