import Foundation
import Observation
import SwiftData
import Supabase
import Network

// The RPC derives row ownership from auth.uid(). expectedUserID is an assertion
// that also prevents an in-flight request from crossing an account switch.
struct LibrarySyncRequest: Codable, Sendable {
    let expectedUserID: UUID
    let changes: [LibraryChange]
    let sinceRevision: Int64
    let limit: Int

    enum CodingKeys: String, CodingKey {
        case expectedUserID = "p_expected_user_id"
        case changes = "p_changes"
        case sinceRevision = "p_since_revision"
        case limit = "p_limit"
    }
}

struct LibraryBookSnapshot: Codable, Sendable {
    let id: UUID?
    let provider: String
    let providerID: String
    let title: String
    let author: String
    let isbn: String?
    let coverURL: String?

    enum CodingKeys: String, CodingKey {
        case id, provider, title, author, isbn
        case providerID = "provider_id"
        case coverURL = "cover_url"
    }

    var catalogID: String {
        provider == "google" ? providerID : "\(provider):\(providerID)"
    }
}

struct LibraryChange: Codable, Sendable {
    let operationID: UUID
    let entryID: UUID
    let expectedRevision: Int64
    let deleted: Bool
    let book: LibraryBookSnapshot
    var readingData: StoryGraphReadingData? = nil

    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case entryID = "entry_id"
        case expectedRevision = "expected_revision"
        case deleted, book
        case readingData = "reading_data"
    }
}

struct RemoteLibraryEntry: Codable, Sendable {
    let id: UUID
    let bookID: UUID
    let revision: Int64
    let updatedAt: String
    let deletedAt: String?
    let book: LibraryBookSnapshot
    var readingData: StoryGraphReadingData? = nil

    enum CodingKeys: String, CodingKey {
        case id, revision, book
        case bookID = "book_id"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case readingData = "reading_data"
    }
}

struct LibrarySyncResponse: Codable, Sendable {
    struct Result: Codable, Sendable {
        enum Status: String, Codable, Sendable { case applied, conflict }
        let operationID: UUID
        let status: Status
        let entry: RemoteLibraryEntry

        enum CodingKeys: String, CodingKey {
            case operationID = "operation_id"
            case status, entry
        }
    }

    let results: [Result]
    let entries: [RemoteLibraryEntry]
    let nextRevision: Int64
    let hasMore: Bool
    let currentRevision: Int64

    enum CodingKeys: String, CodingKey {
        case results, entries
        case nextRevision = "next_revision"
        case hasMore = "has_more"
        case currentRevision = "current_revision"
    }
}

protocol LibrarySyncTransport: Sendable {
    func authenticatedUserID() async throws -> UUID
    func synchronize(_ request: LibrarySyncRequest) async throws -> LibrarySyncResponse
}

/// Network and response decoding stay off the model context's main actor.
actor SupabaseLibrarySyncTransport: LibrarySyncTransport {
    private let client: SupabaseClient

    init(client: SupabaseClient) { self.client = client }

    func authenticatedUserID() async throws -> UUID {
        try await client.auth.session.user.id
    }

    func synchronize(_ request: LibrarySyncRequest) async throws -> LibrarySyncResponse {
        guard try await authenticatedUserID() == request.expectedUserID else {
            throw LibraryRepositoryError.accountChanged
        }
        return try await client.rpc("textual_sync_library", params: request).execute().value
    }
}

enum LibraryRepositoryError: LocalizedError {
    case inactive, accountChanged, wrongAccountStore, wrongContext, missingCatalogID, invalidResponse

    var errorDescription: String? {
        switch self {
        case .inactive, .accountChanged:
            return "Your account changed. Reopen your library to continue syncing."
        case .wrongAccountStore, .wrongContext:
            return "This library does not belong to the active account."
        case .missingCatalogID:
            return "This book is missing its catalog reference. Add it again from book search."
        case .invalidResponse:
            return "The library service returned an unexpected response. Your local changes are still saved."
        }
    }
}

struct StoryGraphImportPreview: Equatable, Sendable {
    var added = 0
    var updated = 0
    var unchanged = 0
    var total: Int { added + updated + unchanged }
}

@MainActor
@Observable
final class LibraryRepository {
    enum SyncState: Equatable { case idle, syncing, queued, offline, failed, conflict }

    private(set) var syncState: SyncState = .idle
    private(set) var message: String?
    let userID: UUID

    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let transport: any LibrarySyncTransport
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var networkMonitor: NWPathMonitor?
    @ObservationIgnored private var active = true
    @ObservationIgnored private var generation = UUID()

    convenience init(client: SupabaseClient, userID: UUID, modelContext: ModelContext) {
        self.init(userID: userID, modelContext: modelContext,
                  transport: SupabaseLibrarySyncTransport(client: client))
    }

    init(userID: UUID, modelContext: ModelContext, transport: any LibrarySyncTransport) {
        self.userID = userID
        self.modelContext = modelContext
        self.transport = transport
    }

    /// Start once while this account's library is onscreen. Foreground/mutation
    /// callers can also synchronize; requests are coalesced by the owned task.
    func start() {
        guard active, networkMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in await self?.synchronize() }
        }
        networkMonitor = monitor
        monitor.start(queue: DispatchQueue(label: "textual.library-connectivity"))
    }

    /// Call before releasing the account's model container on sign-out.
    func stop() {
        active = false
        generation = UUID()
        syncTask?.cancel()
        syncTask = nil
        networkMonitor?.cancel()
        networkMonitor = nil
        syncState = .idle
        message = nil
    }

    @discardableResult
    func add(_ book: Book) throws -> Book {
        try requireActive()
        let identity = try snapshot(for: book).catalogID
        if let existing = try allBooks().first(where: { $0.googleBooksVolumeId == identity }) {
            if existing.isRemovedFromLibrary {
                existing.isRemovedFromLibrary = false
                existing.title = book.title
                existing.author = book.author
                existing.coverURL = book.coverURL
                existing.isbn = book.isbn
                try save(existing)
            }
            return existing
        }
        if let context = book.modelContext, context !== modelContext {
            throw LibraryRepositoryError.wrongContext
        }
        if book.modelContext == nil { modelContext.insert(book) }
        book.isRemovedFromLibrary = false
        try save(book)
        return book
    }

    /// Mutations and their exact retry payload are committed together locally.
    func save(_ book: Book) throws {
        try save([book])
    }

    /// Save a queue reorder and all of its retry payloads in one local transaction.
    func save(_ books: [Book]) throws {
        try requireActive()
        guard books.allSatisfy({ $0.modelContext === modelContext }) else {
            throw LibraryRepositoryError.wrongContext
        }
        do {
            for book in books {
                book.pendingOperationID = UUID()
                book.pendingOperationData = try JSONEncoder().encode(change(for: book))
            }
            try modelContext.save()
        } catch {
            rollbackPendingChanges()
            throw error
        }
        if books.allSatisfy({ $0.syncConflictData == nil }) {
            syncState = .queued
            message = "Changes are saved on this iPhone and waiting to sync."
        } else {
            showConflict()
        }
    }

    func remove(_ book: Book) throws {
        try requireActive()
        guard book.modelContext === modelContext else { throw LibraryRepositoryError.wrongContext }
        book.isRemovedFromLibrary = true
        try save(book)
    }

    /// Preview is read-only. Confirmation recomputes matches against the current
    /// account store so edits/sync between preview and confirmation cannot stale it.
    func previewStoryGraphImport(_ document: StoryGraphDocument) throws -> StoryGraphImportPreview {
        try requireActive()
        return try storyGraphPlan(document).summary
    }

    @discardableResult
    func importStoryGraph(_ document: StoryGraphDocument, expectedUserID: UUID) async throws -> StoryGraphImportPreview {
        try requireActive()
        let run = generation
        guard expectedUserID == userID, try await transport.authenticatedUserID() == userID else {
            throw LibraryRepositoryError.accountChanged
        }
        try checkRun(run)
        let plan = try storyGraphPlan(document)
        do {
            _ = try syncCheckpoint() // Reject a mismatched account store before any writes.
            for (record, existing) in plan.matches {
                if let existing, !existing.isRemovedFromLibrary, existing.importedReading == record.reading.preservingQueue(from: existing.importedReading) { continue }
                let book: Book
                if let existing { book = existing }
                else {
                    book = Book(title: record.title, author: record.author, isbn: record.isbn ?? "",
                                coverURL: record.isbn.map { "https://covers.openlibrary.org/b/isbn/\($0)-M.jpg?default=false" } ?? "",
                                googleBooksVolumeId: record.catalogID)
                    modelContext.insert(book)
                }
                let reading = record.reading.preservingQueue(from: book.importedReading)
                book.storyGraphData = try JSONEncoder().encode(reading)
                book.isRemovedFromLibrary = false
                book.pendingOperationID = UUID()
                book.pendingOperationData = try JSONEncoder().encode(change(for: book))
            }
            // One local transaction: a bad row/save never leaves half an import.
            try commit()
        } catch {
            rollbackPendingChanges()
            throw error
        }
        if plan.summary.added + plan.summary.updated > 0 {
            syncState = .queued
            message = "Your imported reading data is saved on this iPhone and waiting to sync."
        }
        return plan.summary
    }

    private func storyGraphPlan(_ document: StoryGraphDocument) throws
        -> (matches: [(StoryGraphRecord, Book?)], summary: StoryGraphImportPreview) {
        let books = try allBooks()
        let bySource = Dictionary(grouping: books.filter { $0.importedReading != nil }, by: { $0.importedReading!.sourceKey })
        let byCatalog = Dictionary(grouping: books, by: { $0.googleBooksVolumeId ?? "" })
        let byISBN = Dictionary(grouping: books.filter { StoryGraphImporter.normalizedISBN($0.isbn) != nil },
                                by: { StoryGraphImporter.normalizedISBN($0.isbn)! })
        func name(_ title: String, _ author: String) -> String {
            StoryGraphImporter.normalizedName(title) + "|" + StoryGraphImporter.normalizedName(author)
        }
        let byName = Dictionary(grouping: books, by: { name($0.title, $0.author) })
        var used = Set<UUID>()
        var summary = StoryGraphImportPreview()
        var matches: [(StoryGraphRecord, Book?)] = []
        for record in document.records {
            let candidates: [Book]
            if let exact = bySource[record.reading.sourceKey] ?? byCatalog[record.catalogID] { candidates = exact }
            else if let isbn = record.isbn, let exact = byISBN[isbn] { candidates = exact }
            else {
                candidates = (byName[name(record.title, record.author)] ?? []).filter {
                    guard let theirISBN = StoryGraphImporter.normalizedISBN($0.isbn), let incoming = record.isbn else { return true }
                    return theirISBN == incoming
                }
            }
            guard candidates.count <= 1 else {
                throw StoryGraphImportError.invalid("More than one saved book matches “\(record.title)”. Resolve the duplicates in My Archive before importing.")
            }
            let existing = candidates.first
            if let existing {
                guard used.insert(existing.id).inserted else {
                    throw StoryGraphImportError.invalid("Multiple export rows match “\(existing.title)” in My Archive. Review those editions before importing.")
                }
                guard existing.syncConflictData == nil else {
                    throw StoryGraphImportError.invalid("Resolve the sync conflict for “\(existing.title)” before importing.")
                }
                if !existing.isRemovedFromLibrary, existing.importedReading == record.reading.preservingQueue(from: existing.importedReading) { summary.unchanged += 1 }
                else { summary.updated += 1 }
            } else { summary.added += 1 }
            matches.append((record, existing))
        }
        return (matches, summary)
    }

    func resolveConflictKeepingLocal(_ book: Book) throws {
        try requireActive()
        guard book.modelContext === modelContext else { throw LibraryRepositoryError.wrongContext }
        guard let data = book.syncConflictData else { return }
        let remote = try JSONDecoder().decode(RemoteLibraryEntry.self, from: data)
        book.serverEntryID = remote.id
        book.canonicalBookID = remote.bookID
        book.serverRevision = max(book.serverRevision, remote.revision)
        book.syncConflictData = nil
        try save(book)
    }

    func resolveConflictUsingServer(_ book: Book) throws {
        try requireActive()
        guard book.modelContext === modelContext else { throw LibraryRepositoryError.wrongContext }
        guard let data = book.syncConflictData else { return }
        let remote = try JSONDecoder().decode(RemoteLibraryEntry.self, from: data)
        book.pendingOperationID = nil
        book.pendingOperationData = nil
        book.syncConflictData = nil
        apply(remote, to: book)
        try commit()
        syncState = .idle
        message = nil
    }

    func synchronize() async {
        guard active else { return }
        if let syncTask {
            await syncTask.value
            return
        }
        let run = generation
        let task = Task<Void, Never> { [weak self] in
            await self?.runSynchronization(generation: run)
        }
        syncTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if generation == run { syncTask = nil }
    }

    private func runSynchronization(generation run: UUID) async {
        syncState = .syncing
        message = nil
        do {
            let checkpoint = try syncCheckpoint()
            // Keep each foreground sync bounded; queued work survives app restarts.
            for _ in 0..<5 {
                try checkRun(run)
                guard try await transport.authenticatedUserID() == userID else {
                    throw LibraryRepositoryError.accountChanged
                }
                try checkRun(run)
                let pendingBooks = try allBooks().filter {
                    $0.pendingOperationID != nil && $0.syncConflictData == nil
                }.prefix(50)
                var changes: [LibraryChange] = []
                var submitted: [UUID: Book] = [:]
                var batchBytes = 0
                for book in pendingBooks {
                    let operation: LibraryChange
                    if let data = book.pendingOperationData {
                        operation = try JSONDecoder().decode(LibraryChange.self, from: data)
                        guard operation.operationID == book.pendingOperationID else {
                            throw LibraryRepositoryError.invalidResponse
                        }
                    } else {
                        operation = try change(for: book)
                        book.pendingOperationData = try JSONEncoder().encode(operation)
                    }
                    let encodedSize = try JSONEncoder().encode(operation).count
                    if !changes.isEmpty, batchBytes + encodedSize > 750_000 { break }
                    batchBytes += encodedSize
                    changes.append(operation)
                    submitted[operation.operationID] = book
                }
                try commit()
                let request = LibrarySyncRequest(expectedUserID: userID, changes: changes,
                                                 sinceRevision: checkpoint.revision, limit: 200)
                let response = try await transport.synchronize(request)
                try checkRun(run)
                guard try await transport.authenticatedUserID() == userID else {
                    throw LibraryRepositoryError.accountChanged
                }
                try checkRun(run)
                try validate(response, for: request)
                for result in response.results {
                    guard let book = submitted[result.operationID] else {
                        throw LibraryRepositoryError.invalidResponse
                    }
                    try acknowledge(result, for: book)
                }
                var localBooks = try allBooks()
                for entry in response.entries {
                    try merge(entry, books: &localBooks)
                }
                checkpoint.revision = response.nextRevision
                // A failed save must never advance the persisted pull cursor.
                try commit()
                let books = try allBooks()
                let hasPending = books.contains { $0.pendingOperationID != nil && $0.syncConflictData == nil }
                if !response.hasMore && !hasPending {
                    if books.contains(where: { $0.syncConflictData != nil }) {
                        showConflict()
                    } else {
                        syncState = .idle
                        message = nil
                    }
                    return
                }
            }
            syncState = .queued
            message = "More library changes are waiting. Sync again to continue."
        } catch {
            guard active, generation == run else { return }
            if error is CancellationError || Task.isCancelled {
                syncState = .queued
                message = "Your changes are saved and will sync next time."
            } else if let error = error as? URLError,
                      [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(error.code) {
                syncState = .offline
                message = "You're offline. Your saved library is available, and changes will sync when you reconnect."
            } else {
                syncState = .failed
                message = (error as? LocalizedError)?.errorDescription
                    ?? "Your library couldn't sync. Your local changes are still saved. Try again."
            }
        }
    }

    private func acknowledge(_ result: LibrarySyncResponse.Result, for book: Book) throws {
        let remote = result.entry
        let isCurrentOperation = book.pendingOperationID == result.operationID
        if result.status == .conflict {
            try recordConflict(remote, for: book)
            return
        }
        book.serverEntryID = remote.id
        book.canonicalBookID = remote.bookID
        if isCurrentOperation {
            book.pendingOperationID = nil
            book.pendingOperationData = nil
            book.syncConflictData = nil
            apply(remote, to: book)
        } else {
            // A local edit made while the request was in flight still needs sending.
            // It has not been submitted yet, so rebase its frozen payload on this ACK.
            book.serverRevision = max(book.serverRevision, remote.revision)
            if book.pendingOperationID != nil {
                book.pendingOperationData = try JSONEncoder().encode(change(for: book))
            }
        }
    }

    private func merge(_ remote: RemoteLibraryEntry, books: inout [Book]) throws {
        if let local = books.first(where: {
            $0.serverEntryID == remote.id || $0.id == remote.id ||
            $0.canonicalBookID == remote.bookID || $0.googleBooksVolumeId == remote.book.catalogID
        }) {
            guard remote.revision >= local.serverRevision else { return }
            if local.pendingOperationID != nil {
                if remote.revision > local.serverRevision {
                    try recordConflict(remote, for: local)
                }
            } else {
                apply(remote, to: local)
            }
            return
        }
        let local = Book(id: remote.id, title: remote.book.title, author: remote.book.author,
                         isbn: remote.book.isbn ?? remote.book.catalogID,
                         coverURL: remote.book.coverURL ?? "", googleBooksVolumeId: remote.book.catalogID)
        local.pendingOperationID = nil
        modelContext.insert(local)
        books.append(local)
        apply(remote, to: local)
    }

    private func apply(_ remote: RemoteLibraryEntry, to book: Book) {
        guard remote.revision >= book.serverRevision else { return }
        book.serverEntryID = remote.id
        book.canonicalBookID = remote.bookID
        book.serverRevision = remote.revision
        book.title = remote.book.title
        book.author = remote.book.author
        book.isbn = remote.book.isbn ?? remote.book.catalogID
        book.coverURL = remote.book.coverURL ?? ""
        book.googleBooksVolumeId = remote.book.catalogID
        book.isRemovedFromLibrary = remote.deletedAt != nil
        book.storyGraphData = remote.readingData.flatMap { try? JSONEncoder().encode($0) }
    }

    private func recordConflict(_ remote: RemoteLibraryEntry, for book: Book) throws {
        guard remote.revision >= book.serverRevision else { return }
        book.serverEntryID = remote.id
        book.canonicalBookID = remote.bookID
        book.serverRevision = remote.revision
        book.syncConflictData = try JSONEncoder().encode(remote)
    }

    private func validate(_ response: LibrarySyncResponse, for request: LibrarySyncRequest) throws {
        let expected = Set(request.changes.map(\.operationID))
        let actual = response.results.map(\.operationID)
        guard Set(actual) == expected, actual.count == expected.count,
              response.nextRevision >= request.sinceRevision,
              response.nextRevision <= response.currentRevision,
              response.entries.count <= request.limit,
              !response.hasMore || response.nextRevision > request.sinceRevision else {
            throw LibraryRepositoryError.invalidResponse
        }
        var last = request.sinceRevision
        for entry in response.entries {
            guard entry.revision > last, entry.revision <= response.nextRevision,
                  ["google", "openlibrary", "storygraph"].contains(entry.book.provider) else {
                throw LibraryRepositoryError.invalidResponse
            }
            last = entry.revision
        }
        guard response.nextRevision == last else { throw LibraryRepositoryError.invalidResponse }
    }

    private func change(for book: Book) throws -> LibraryChange {
        guard let operationID = book.pendingOperationID else { throw LibraryRepositoryError.invalidResponse }
        return LibraryChange(operationID: operationID, entryID: book.serverEntryID ?? book.id,
                             expectedRevision: book.serverRevision, deleted: book.isRemovedFromLibrary,
                             book: try snapshot(for: book), readingData: try book.storyGraphData.map {
                                 try JSONDecoder().decode(StoryGraphReadingData.self, from: $0)
                             })
    }

    private func snapshot(for book: Book) throws -> LibraryBookSnapshot {
        guard let catalogID = book.googleBooksVolumeId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !catalogID.isEmpty else { throw LibraryRepositoryError.missingCatalogID }
        let isOpenLibrary = catalogID.hasPrefix("openlibrary:")
        let isStoryGraph = catalogID.hasPrefix("storygraph:")
        let provider = isOpenLibrary ? "openlibrary" : (isStoryGraph ? "storygraph" : "google")
        let providerID = provider == "google" ? catalogID : String(catalogID.dropFirst(provider.count + 1))
        guard !providerID.isEmpty else { throw LibraryRepositoryError.missingCatalogID }
        let isbn = book.isbn.filter { $0 != "-" && !$0.isWhitespace }.uppercased()
        let digits = "0123456789"
        let validISBN = (isbn.count == 13 && isbn.allSatisfy { digits.contains($0) }) ||
            (isbn.count == 10 && isbn.dropLast().allSatisfy { digits.contains($0) } &&
             isbn.last.map { digits.contains($0) || $0 == "X" } == true)
        var cover = URLComponents(string: book.coverURL)
        let allowedHosts = ["books.google.com", "books.googleusercontent.com", "covers.openlibrary.org"]
        if let host = cover?.host?.lowercased(), allowedHosts.contains(host),
           cover?.user == nil, cover?.password == nil,
           ["https", "http"].contains(cover?.scheme?.lowercased() ?? "") {
            cover?.scheme = "https"
        } else {
            cover = nil
        }
        let title = book.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return LibraryBookSnapshot(id: nil, provider: provider,
                                   providerID: providerID, title: String((title.isEmpty ? "No Title" : title).prefix(1000)),
                                   author: String(book.author.prefix(1000)), isbn: validISBN ? isbn : nil,
                                   coverURL: cover?.string)
    }

    private func allBooks() throws -> [Book] { try modelContext.fetch(FetchDescriptor<Book>()) }

    private func commit() throws {
        do {
            try modelContext.save()
        } catch {
            rollbackPendingChanges()
            throw error
        }
    }

    private func rollbackPendingChanges(restoring editedBook: Book? = nil) {
        modelContext.processPendingChanges()
        var books = modelContext.changedModelsArray.compactMap { $0 as? Book }
        if let editedBook, !books.contains(where: { $0 === editedBook }) {
            books.append(editedBook)
        }
        let checkpoints = modelContext.changedModelsArray.compactMap { $0 as? LibrarySyncState }
        modelContext.rollback()
        guard !books.isEmpty || !checkpoints.isEmpty else { return }

        do {
            // rollback() protects the store, but SwiftData can leave already
            // observed model instances holding their pre-rollback values. Read
            // committed values independently and repair those same instances.
            let savedContext = ModelContext(modelContext.container)
            let savedBooks = try savedContext.fetch(FetchDescriptor<Book>())
            let savedCheckpoints = try savedContext.fetch(FetchDescriptor<LibrarySyncState>())
            for book in books {
                guard let saved = savedBooks.first(where: { $0.id == book.id }) else { continue }
                book.title = saved.title
                book.author = saved.author
                book.isbn = saved.isbn
                book.coverURL = saved.coverURL
                book.googleBooksVolumeId = saved.googleBooksVolumeId
                book.cachedCatalogMetadata = saved.cachedCatalogMetadata
                book.catalogMetadataUpdatedAt = saved.catalogMetadataUpdatedAt
                book.storyGraphData = saved.storyGraphData
                book.serverEntryID = saved.serverEntryID
                book.canonicalBookID = saved.canonicalBookID
                book.serverRevision = saved.serverRevision
                book.pendingOperationID = saved.pendingOperationID
                book.pendingOperationData = saved.pendingOperationData
                book.syncConflictData = saved.syncConflictData
                book.isRemovedFromLibrary = saved.isRemovedFromLibrary
                book.tags = saved.tags.compactMap {
                    modelContext.model(for: $0.persistentModelID) as? Tag
                }
            }
            for checkpoint in checkpoints {
                if let saved = savedCheckpoints.first(where: { $0.userID == checkpoint.userID }) {
                    checkpoint.revision = saved.revision
                }
            }
        } catch {
            // If the store itself cannot be read, never upload stale in-memory
            // values. Reopening the account creates a fresh model context.
            stop()
            syncState = .failed
            message = "Your saved library couldn’t be reloaded. Sign out and sign in to reopen it."
        }
    }

    private func syncCheckpoint() throws -> LibrarySyncState {
        let states = try modelContext.fetch(FetchDescriptor<LibrarySyncState>())
        guard states.allSatisfy({ $0.userID == userID }) else { throw LibraryRepositoryError.wrongAccountStore }
        if let state = states.first { return state }
        let state = LibrarySyncState(userID: userID)
        modelContext.insert(state)
        return state
    }

    private func checkRun(_ run: UUID) throws {
        try Task.checkCancellation()
        try requireActive()
        guard generation == run else { throw CancellationError() }
    }

    private func requireActive() throws {
        guard active else { throw LibraryRepositoryError.inactive }
    }

    private func showConflict() {
        syncState = .conflict
        message = "A book changed on another device. Your local changes are kept; choose which version to use."
    }
}
