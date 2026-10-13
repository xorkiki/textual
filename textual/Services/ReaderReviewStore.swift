import Foundation
import SwiftData
import Supabase

protocol ReaderReviewTransport: Sendable {
    func authenticatedUserID() async throws -> UUID
    func read(userID: UUID, bookID: UUID) async throws -> RemoteReaderReview?
    func submit(_ mutation: ReaderReviewMutation) async throws -> ReaderReviewResult
    func summary(bookID: UUID) async throws -> CommunityReviewSummary?
    func terms() async throws -> [ReaderReviewTerm]
    func list(userID: UUID, offset: Int, limit: Int) async throws -> [RemoteReaderReview]
}

actor SupabaseReaderReviewTransport: ReaderReviewTransport {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }
    func authenticatedUserID() async throws -> UUID { try await client.auth.session.user.id }
    func read(userID: UUID, bookID: UUID) async throws -> RemoteReaderReview? {
        guard try await authenticatedUserID() == userID else { throw LibraryRepositoryError.accountChanged }
        struct Parameters: Encodable { let p_expected_user_id: UUID; let p_book_id: UUID }
        return try await client.rpc("textual_read_own_review", params: Parameters(p_expected_user_id: userID, p_book_id: bookID)).execute().value
    }
    func submit(_ mutation: ReaderReviewMutation) async throws -> ReaderReviewResult {
        guard try await authenticatedUserID() == mutation.expectedUserID else { throw LibraryRepositoryError.accountChanged }
        return try await client.rpc("textual_save_review", params: mutation).execute().value
    }
    func summary(bookID: UUID) async throws -> CommunityReviewSummary? {
        struct Parameters: Encodable { let p_book_id: UUID }
        return try await client.rpc("textual_read_review_summary", params: Parameters(p_book_id: bookID)).execute().value
    }
    func list(userID: UUID, offset: Int, limit: Int) async throws -> [RemoteReaderReview] {
        guard try await authenticatedUserID() == userID else { throw LibraryRepositoryError.accountChanged }
        return try await client.from("textual_reviews")
            .select("workID:work_id,bookID:book_id,revision,content,deleted")
            .eq("user_id", value: userID).order("work_id")
            .range(from: offset, to: offset + limit - 1).execute().value
    }
    func terms() async throws -> [ReaderReviewTerm] {
        try await client.from("textual_review_terms").select().eq("kind", value: "mood").order("kind").order("label").execute().value
    }
}

/// Account-owned review API shared by every review entry point. No background publication:
/// saveDraft is local; queueSubmission is an explicit save/share action; flush
/// retries only that already-authorized, durable payload.
@MainActor
final class ReaderReviewStore {
    let userID: UUID
    private let context: ModelContext
    private let transport: any ReaderReviewTransport
    private let repository: LibraryRepository?
    private var isFlushing = false
    private var active = true

    init(userID: UUID, context: ModelContext, transport: any ReaderReviewTransport,
         repository: LibraryRepository? = nil) {
        self.userID = userID; self.context = context; self.transport = transport
        self.repository = repository
    }
    func stop() { active = false }

    func draft(for book: Book) throws -> ReaderReviewDraft? {
        try check(book)
        let key = ReaderReviewDraft.key(userID: userID, bookID: book.id)
        return try context.fetch(FetchDescriptor<ReaderReviewDraft>(predicate: #Predicate { $0.key == key })).first
    }
    @discardableResult
    func saveDraft(_ content: ReaderReviewContent, for book: Book, isUserEdit: Bool = true) throws -> ReaderReviewDraft {
        let content = try content.validated()
        if let draft = try draft(for: book) {
            draft.contentData = try JSONEncoder().encode(content)
            if isUserEdit { draft.hasLocalEdits = true }
            try context.save()
            return draft
        }
        let draft = try ReaderReviewDraft(userID: userID, localBookID: book.id, content: content)
        draft.hasLocalEdits = isUserEdit
        context.insert(draft)
        try context.save()
        return draft
    }

    /// Run on opening the editor. A local draft is never replaced by a download.
    func loadRemote(for book: Book) async throws {
        try check(book)
        guard let id = book.canonicalBookID else { throw ReaderReviewError.bookNotSynced }
        guard try draft(for: book)?.pendingData == nil else { throw ReaderReviewError.submissionPending }
        try await checkAccount()
        let remote = try await transport.read(userID: userID, bookID: id)
        try await checkAccount()
        // A user may have submitted while the read was in flight.
        guard try draft(for: book)?.pendingData == nil else { throw ReaderReviewError.submissionPending }
        try cache(remote, for: book)
        if try draft(for: book)?.conflict != nil { throw ReaderReviewError.conflict }
    }

    /// Download only this reader's rows, in pages, into the account-local cache.
    func refreshLibrary() async throws {
        try await checkAccount()
        let books = try context.fetch(FetchDescriptor<Book>())
        let byID = Dictionary(grouping: books.compactMap { book in
            book.canonicalBookID.map { ($0, book) }
        }, by: { $0.0 })
        var offset = 0
        while true {
            let page = try await transport.list(userID: userID, offset: offset, limit: 100)
            try await checkAccount()
            for remote in page {
                for (_, book) in byID[remote.bookID] ?? [] {
                    if try draft(for: book)?.pending == nil { try cache(remote, for: book) }
                }
            }
            if page.count < 100 { break }
            offset += page.count
        }
    }

    private func cache(_ remote: RemoteReaderReview?, for book: Book) throws {
        let draft = try self.draft(for: book)
            ?? saveDraft(remote.flatMap { $0.deleted ? nil : $0.content } ?? .init(), for: book, isUserEdit: false)
        guard draft.pending == nil else { return }
        // Reads can finish out of order, including after a successful save.
        // Server withdrawals are versioned tombstones, never an absent row.
        if let current = draft.remote, (remote?.revision ?? 0) < current.revision { return }
        if let remote, draft.remote?.revision != remote.revision,
           draft.hasUnsavedChanges, draft.content != (remote.deleted ? .init() : remote.content) {
            draft.conflictData = try JSONEncoder().encode(remote)
        } else {
            if !draft.hasUnsavedChanges {
                draft.contentData = try JSONEncoder().encode(remote.flatMap { $0.deleted ? nil : $0.content } ?? .init())
            }
            draft.remoteData = try remote.map { try JSONEncoder().encode($0) }
            draft.conflictData = nil
        }
        draft.hasLoadedRemote = true
        try context.save()
    }

    func queueSubmission(for book: Book, deleted: Bool = false) throws {
        guard !book.isRemovedFromLibrary || deleted else { throw ReaderReviewError.bookNotSynced }
        guard let draft = try draft(for: book), draft.hasLoadedRemote else { throw ReaderReviewError.loadRemoteFirst }
        guard draft.pendingData == nil else { throw ReaderReviewError.submissionPending }
        guard draft.conflictData == nil else { throw ReaderReviewError.conflict }
        guard let id = book.canonicalBookID else { throw ReaderReviewError.bookNotSynced }
        guard let content = draft.content else { throw ReaderReviewError.invalidContent }
        // Withdrawal removes text/tags from the active review, not from private imports.
        let mutation = ReaderReviewMutation(expectedUserID: userID, operationID: UUID(), bookID: id,
            expectedRevision: draft.remote?.revision ?? 0,
            content: deleted ? ReaderReviewContent() : try content.validated(), deleted: deleted)
        draft.pendingData = try JSONEncoder().encode(mutation)
        do {
            if !deleted, content.hasAssessment, book.importedReading?.status != "read" {
                // Commit the review submission, completion, and library outbox in
                // one local save. Draft typing and downloads never reach this path.
                try BookReadingActions.setStatus("read", book: book, context: context, repository: repository)
            } else {
                // Editing a read book preserves its original completion history.
                try context.save()
            }
        } catch {
            draft.pendingData = nil
            throw error
        }
    }

    func flush() async throws {
        guard active else { throw LibraryRepositoryError.inactive }
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        let owner = userID
        let drafts = try context.fetch(FetchDescriptor<ReaderReviewDraft>(predicate: #Predicate { $0.userID == owner }))
        for draft in drafts where draft.pendingData != nil {
            guard let mutation = draft.pending, mutation.expectedUserID == userID else { throw ReaderReviewError.invalidContent }
            try await checkAccount()
            let result = try await transport.submit(mutation)
            try await checkAccount()
            guard let remote = result.review, remote.revision > 0 else { throw ReaderReviewError.invalidResponse }
            switch result.status {
            case .applied:
                guard remote.bookID == mutation.bookID, remote.revision == mutation.expectedRevision + 1,
                      remote.content == mutation.content, remote.deleted == mutation.deleted else { throw ReaderReviewError.invalidResponse }
                draft.remoteData = try JSONEncoder().encode(remote)
                draft.pendingData = nil
            case .conflict:
                draft.conflictData = try JSONEncoder().encode(remote)
                draft.pendingData = nil
            }
            try context.save()
        }
    }

    /// A conflict is resolved explicitly; a fresh submission still requires queueSubmission.
    func resolveConflict(for book: Book, keepLocal: Bool) throws {
        guard let draft = try draft(for: book), let remote = draft.conflict else { return }
        if !keepLocal { draft.contentData = try JSONEncoder().encode(remote.deleted ? ReaderReviewContent() : remote.content) }
        draft.remoteData = try JSONEncoder().encode(remote)
        draft.conflictData = nil
        draft.hasLoadedRemote = true
        try context.save()
    }

    private func check(_ book: Book) throws {
        guard active else { throw LibraryRepositoryError.inactive }
        guard book.modelContext === context else { throw LibraryRepositoryError.wrongContext }
    }
    private func checkAccount() async throws {
        try Task.checkCancellation()
        guard active else { throw LibraryRepositoryError.inactive }
        guard try await transport.authenticatedUserID() == userID else { throw LibraryRepositoryError.accountChanged }
        guard active else { throw LibraryRepositoryError.inactive }
        try Task.checkCancellation()
    }
}
