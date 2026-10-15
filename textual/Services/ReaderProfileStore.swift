import Foundation
import Observation
import SwiftData
import Supabase

protocol ReaderProfileTransport: ReaderAvatarTransport {
    func fetch(username: String) async throws -> PublicReaderProfile?
    func publish(userID: UUID, revision: Int, content: ReaderPublicContent) async throws -> PublicReaderProfile
    /// Shelf additions travel with the card in one server transaction.
    func publish(userID: UUID, revision: Int, content: ReaderPublicContent,
                 activity: [SocialActivityIntent]) async throws -> PublicReaderProfile
}

extension ReaderProfileTransport {
    func publish(userID: UUID, revision: Int, content: ReaderPublicContent,
                 activity: [SocialActivityIntent]) async throws -> PublicReaderProfile {
        try await publish(userID: userID, revision: revision, content: content)
    }
}

actor SupabaseReaderProfileTransport: ReaderProfileTransport {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func uploadAvatar(userID: UUID, path: String, data: Data) async throws {
        guard try await client.auth.session.user.id == userID else { throw LibraryRepositoryError.accountChanged }
        guard ReaderAvatar.isValid(path: path, userID: userID), data.count <= ReaderAvatar.maximumBytes else {
            throw ReaderAvatar.PhotoError.invalid
        }
        try await client.storage.from(ReaderAvatar.bucket).upload(path, data: data,
            options: FileOptions(contentType: "image/jpeg", upsert: true))
    }

    func downloadAvatar(path: String) async throws -> Data {
        guard ReaderAvatar.isValid(path: path) else { throw ReaderAvatar.PhotoError.invalid }
        return try await client.storage.from(ReaderAvatar.bucket).download(path: path)
    }

    func fetch(username: String) async throws -> PublicReaderProfile? {
        struct Parameters: Encodable { let p_username: String }
        return try await client.rpc("textual_read_reader_profile", params: Parameters(p_username: username)).execute().value
    }

    func publish(userID: UUID, revision: Int, content: ReaderPublicContent) async throws -> PublicReaderProfile {
        try await publish(userID: userID, revision: revision, content: content, activity: [])
    }

    func publish(userID: UUID, revision: Int, content: ReaderPublicContent,
                 activity: [SocialActivityIntent]) async throws -> PublicReaderProfile {
        guard try await client.auth.session.user.id == userID else { throw LibraryRepositoryError.accountChanged }
        struct Parameters: Encodable {
            let p_expected_user_id: UUID
            let p_expected_revision: Int
            let p_content: ReaderPublicContent
            /// Omitted when empty, so publishing works before the social migration.
            let p_activity: [SocialActivityIntent]?
        }
        return try await client.rpc("textual_publish_reader_profile", params: Parameters(
            p_expected_user_id: userID, p_expected_revision: revision, p_content: content,
            p_activity: activity.isEmpty ? nil : activity)).execute().value
    }
}

@MainActor
@Observable
final class ReaderProfileStore {
    private(set) var isSyncing = false
    private(set) var message: String?
    private(set) var conflictingProfile: PublicReaderProfile?
    @ObservationIgnored private var syncAgain = false
    @ObservationIgnored private let transport: any ReaderProfileTransport
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let userID: UUID

    init(userID: UUID, context: ModelContext, transport: any ReaderProfileTransport) {
        self.userID = userID; self.context = context; self.transport = transport
    }

    func draft() throws -> ReaderProfileDraft? {
        let id = userID
        return try context.fetch(FetchDescriptor<ReaderProfileDraft>(predicate: #Predicate { $0.userID == id })).first
    }

    /// `addedFavorites` are shelf books the reader just chose; with a sharing stamp
    /// they become shelf intents committed in the same save as the card.
    @discardableResult
    func update(_ content: ReaderPublicContent, addedFavorites: [UUID] = [],
                stamp: SocialActivityStamp? = nil) throws -> ReaderProfileDraft {
        let data = try JSONEncoder().encode(content)
        if let draft = try draft() {
            if draft.content != content {
                draft.contentData = data
                draft.needsUpload = true
                if let stamp, !addedFavorites.isEmpty {
                    let intents = addedFavorites.map { stamp.intent(.shelf, favoriteID: $0) }
                    draft.pendingActivityData = SocialActivityIntent.encodeList(
                        SocialActivityIntent.decodeList(draft.pendingActivityData) + intents)
                }
                try context.save()
            }
            return draft
        }
        let draft = try ReaderProfileDraft(userID: userID, content: content)
        context.insert(draft)
        try context.save()
        return draft
    }

    func setAvatar(_ data: Data) throws {
        guard !data.isEmpty, data.count <= ReaderAvatar.maximumBytes,
              let draft = try draft(), var content = draft.content else { throw ReaderAvatar.PhotoError.invalid }
        let path = ReaderAvatar.path(userID: userID)
        content.avatarPath = path
        draft.contentData = try JSONEncoder().encode(content)
        draft.avatarData = data
        draft.avatarDataPath = path
        draft.avatarNeedsUpload = true
        draft.needsUpload = true
        try context.save()
    }

    func synchronize(username: String) async {
        guard !isSyncing else { syncAgain = true; return }
        guard conflictingProfile == nil else { return }
        isSyncing = true
        defer {
            isSyncing = false
            if syncAgain {
                syncAgain = false
                Task { await self.synchronize(username: username) }
            }
        }
        do {
            guard let draft = try draft() else { return }
            let remote = try await transport.fetch(username: username)
            try Task.checkCancellation()
            if let remote {
                if remote.content == draft.content {
                    // The last response may have been lost after the server committed it.
                    draft.serverRevision = remote.revision
                    draft.needsUpload = false
                    draft.pendingActivityData = nil
                    if draft.avatarDataPath == remote.content.avatarPath { draft.avatarNeedsUpload = false }
                } else if !draft.hasLoadedRemote && draft.content?.favorites.isEmpty == true {
                    // Recover the saved shelf on a fresh device, keeping current local stats.
                    if var content = draft.content {
                        content.favorites = remote.content.favorites
                        if !draft.avatarNeedsUpload { content.avatarPath = remote.content.avatarPath }
                        draft.contentData = try JSONEncoder().encode(content)
                        draft.needsUpload = content != remote.content
                    }
                    draft.serverRevision = remote.revision
                } else if remote.revision != draft.serverRevision {
                    if draft.needsUpload {
                        conflictingProfile = remote
                        message = "Your profile changed on another device. Choose which one to keep."
                        return
                    }
                    draft.contentData = try JSONEncoder().encode(remote.content)
                    draft.serverRevision = remote.revision
                }
            }
            draft.hasLoadedRemote = true
            try context.save()
            if draft.avatarNeedsUpload, let path = draft.avatarDataPath, let data = draft.avatarData {
                try await transport.uploadAvatar(userID: userID, path: path, data: data)
                try Task.checkCancellation()
                // A second selection during upload must get its own upload before publishing.
                guard draft.avatarDataPath == path else { syncAgain = true; return }
                draft.avatarNeedsUpload = false
                try context.save()
            }
            guard draft.needsUpload, let content = draft.content else { message = nil; return }
            let activity = SocialActivityIntent.decodeList(draft.pendingActivityData)
            let published = try await transport.publish(userID: userID, revision: draft.serverRevision,
                                                        content: content, activity: activity)
            try Task.checkCancellation()
            // Edits made while this request was in flight remain queued.
            draft.serverRevision = published.revision
            draft.needsUpload = draft.content != content
            let sent = Set(activity.map(\.id))
            draft.pendingActivityData = SocialActivityIntent.encodeList(
                SocialActivityIntent.decodeList(draft.pendingActivityData).filter { !sent.contains($0.id) })
            try context.save()
            message = nil
        } catch is CancellationError {
            // The durable draft is retried on the next visit/foreground transition.
        } catch {
            message = "Saved on this iPhone. Your public card couldn’t update yet."
        }
    }

    func resolveConflict(keepLocal: Bool) throws {
        guard let remote = conflictingProfile, let draft = try draft() else { return }
        if !keepLocal, var content = draft.content {
            content.favorites = remote.content.favorites
            content.avatarPath = remote.content.avatarPath
            draft.contentData = try JSONEncoder().encode(content)
            draft.avatarNeedsUpload = false
            draft.pendingActivityData = nil
            if draft.avatarDataPath != content.avatarPath {
                draft.avatarData = nil
                draft.avatarDataPath = nil
            }
        }
        draft.serverRevision = remote.revision
        draft.hasLoadedRemote = true
        draft.needsUpload = true
        try context.save()
        conflictingProfile = nil
        message = nil
    }
}
