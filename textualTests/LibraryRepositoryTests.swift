import Foundation
import SwiftData
import Testing
@testable import textual

@MainActor
struct LibraryRepositoryTests {
    @Test func legacyISBNWithXCheckDigitRequiresCatalogResolution() {
        let book = Book(title: "ISBN book", author: "Author", isbn: "0-8044-2957-X")
        #expect(book.volumeIdForDetailFetch == nil)
        book.isbn = "openlibrary:OL123W"
        #expect(book.volumeIdForDetailFetch == "openlibrary:OL123W")
    }

    @Test func mutationsPersistAnOutboxAndRemovalKeepsATombstone() throws {
        let container = try makeContainer()
        let user = UUID()
        let transport = MockLibraryTransport(userID: user)
        let repository = LibraryRepository(userID: user, modelContext: container.mainContext, transport: transport)
        let book = makeBook()
        try repository.add(book)
        let addition = try #require(book.pendingOperationID)
        #expect(book.pendingOperationData != nil)
        try repository.remove(book)
        #expect(book.isRemovedFromLibrary)
        #expect(book.pendingOperationID != addition)
        let reopened = ModelContext(container)
        let saved = try #require(reopened.fetch(FetchDescriptor<Book>()).first)
        #expect(saved.isRemovedFromLibrary)
        let visible = try reopened.fetch(FetchDescriptor<Book>(
            predicate: #Predicate<Book> { !$0.isRemovedFromLibrary }))
        #expect(visible.isEmpty)
        let payload = try JSONDecoder().decode(LibraryChange.self, from: #require(saved.pendingOperationData))
        #expect(payload.deleted)
        #expect(payload.entryID == book.id)
    }

    @Test func offlineRetryReusesTheExactDurableOperation() async throws {
        let container = try makeContainer()
        let user = UUID()
        let transport = MockLibraryTransport(userID: user, offline: true)
        let repository = LibraryRepository(userID: user, modelContext: container.mainContext, transport: transport)
        let book = makeBook()
        try repository.add(book)
        let operationID = book.pendingOperationID
        let payload = book.pendingOperationData
        await repository.synchronize()
        #expect(repository.syncState == .offline)
        #expect(book.pendingOperationID == operationID)
        #expect(book.pendingOperationData == payload)

        await transport.setOffline(false)
        let reopenedContext = ModelContext(container)
        let reopened = LibraryRepository(userID: user, modelContext: reopenedContext, transport: transport)
        await reopened.synchronize()
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].changes.first?.operationID == requests[1].changes.first?.operationID)
        let synced = try #require(reopenedContext.fetch(FetchDescriptor<Book>()).first)
        #expect(synced.pendingOperationID == nil)
        #expect(synced.serverRevision == 1)
        #expect(try reopenedContext.fetch(FetchDescriptor<LibrarySyncState>()).first?.revision == 1)
    }

    @Test func anEditDuringUploadIsNotLostByTheEarlierAcknowledgment() async throws {
        let container = try makeContainer()
        let user = UUID()
        let transport = MockLibraryTransport(userID: user, pauseFirst: true)
        let repository = LibraryRepository(userID: user, modelContext: container.mainContext, transport: transport)
        let book = makeBook()
        try repository.add(book)
        let firstOperation = book.pendingOperationID
        let running = Task { await repository.synchronize() }
        await transport.waitForFirstRequest()
        book.title = "Edited while uploading"
        try repository.save(book)
        let secondOperation = book.pendingOperationID
        await transport.release()
        await running.value
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].changes.first?.operationID == firstOperation)
        #expect(requests[1].changes.first?.operationID == secondOperation)
        #expect(requests[1].changes.first?.expectedRevision == 1)
        #expect(requests[1].changes.first?.book.title == "Edited while uploading")
        #expect(book.title == "Edited while uploading")
        #expect(book.pendingOperationID == nil)
        #expect(book.serverRevision == 2)
    }

    @Test func conflictsKeepLocalChangesUntilExplicitlyResolved() async throws {
        let container = try makeContainer()
        let user = UUID()
        let transport = MockLibraryTransport(userID: user, conflict: true)
        let repository = LibraryRepository(userID: user, modelContext: container.mainContext, transport: transport)
        let book = makeBook()
        try repository.add(book)
        let operationID = book.pendingOperationID
        await repository.synchronize()
        #expect(repository.syncState == .conflict)
        #expect(book.title == "Saved title")
        #expect(book.pendingOperationID == operationID)
        #expect(book.syncConflictData != nil)
        await repository.synchronize()
        let requests = await transport.requests
        #expect(requests.last?.changes.isEmpty == true)
        try repository.resolveConflictKeepingLocal(book)
        #expect(book.pendingOperationID != operationID)
        #expect(book.syncConflictData == nil)
        let payload = try JSONDecoder().decode(LibraryChange.self, from: #require(book.pendingOperationData))
        #expect(payload.expectedRevision == 1)
        #expect(payload.book.title == "Saved title")
    }

    @Test func usingServerResolvesARemovalConflictWithoutLosingStableLocalID() async throws {
        let container = try makeContainer()
        let user = UUID()
        let transport = MockLibraryTransport(userID: user, conflict: true)
        let repository = LibraryRepository(userID: user, modelContext: container.mainContext, transport: transport)
        let book = makeBook()
        try repository.add(book)
        let localID = book.id
        try repository.remove(book)
        await repository.synchronize()
        #expect(book.isRemovedFromLibrary)
        try repository.resolveConflictUsingServer(book)
        #expect(!book.isRemovedFromLibrary)
        #expect(book.title == "Changed on another device")
        #expect(book.id == localID)
        #expect(book.pendingOperationID == nil)
        #expect(book.syncConflictData == nil)
    }

    @Test func wrongAccountNeverSendsTheOutbox() async throws {
        let container = try makeContainer()
        let user = UUID()
        let transport = MockLibraryTransport(userID: UUID())
        let repository = LibraryRepository(userID: user, modelContext: container.mainContext, transport: transport)
        let book = makeBook()
        try repository.add(book)
        await repository.synchronize()
        #expect(await transport.requests.isEmpty)
        #expect(book.pendingOperationID != nil)
        #expect(repository.syncState == .failed)
    }

    @Test func stoppingTheAccountDiscardsAnInFlightResponse() async throws {
        let container = try makeContainer()
        let user = UUID()
        let transport = MockLibraryTransport(userID: user, pauseFirst: true)
        let repository = LibraryRepository(userID: user, modelContext: container.mainContext, transport: transport)
        let book = makeBook()
        try repository.add(book)
        let originalOperation = book.pendingOperationID
        let running = Task { await repository.synchronize() }
        await transport.waitForFirstRequest()
        repository.stop()
        await transport.release()
        await running.value
        #expect(book.pendingOperationID == originalOperation)
        #expect(book.serverRevision == 0)
        #expect(throws: LibraryRepositoryError.self) { try repository.remove(book) }
    }

    @Test func checkpointCannotBeUsedByAnotherAccount() async throws {
        let container = try makeContainer()
        let originalUser = UUID()
        container.mainContext.insert(LibrarySyncState(userID: originalUser))
        try container.mainContext.save()
        let newUser = UUID()
        let transport = MockLibraryTransport(userID: newUser)
        let repository = LibraryRepository(userID: newUser, modelContext: container.mainContext, transport: transport)
        await repository.synchronize()
        #expect(repository.syncState == .failed)
        #expect(await transport.requests.isEmpty)
    }

    @Test func rejectedMutationRestoresThePersistedOutboxAndFields() throws {
        let container = try makeContainer()
        let user = UUID()
        let repository = LibraryRepository(userID: user, modelContext: container.mainContext,
                                           transport: MockLibraryTransport(userID: user))
        let book = makeBook()
        try repository.add(book)
        let operationID = book.pendingOperationID
        let payload = book.pendingOperationData
        book.googleBooksVolumeId = nil
        book.title = "Uncommitted edit"
        book.isRemovedFromLibrary = true
        #expect(throws: LibraryRepositoryError.self) { try repository.save(book) }
        #expect(book.googleBooksVolumeId == "openlibrary:OL123W")
        #expect(book.title == "Saved title")
        #expect(!book.isRemovedFromLibrary)
        #expect(book.pendingOperationID == operationID)
        #expect(book.pendingOperationData == payload)
        #expect(book.modelContext === container.mainContext)
        let reopened = ModelContext(container)
        let saved = try #require(reopened.fetch(FetchDescriptor<Book>()).first)
        #expect(saved.googleBooksVolumeId == "openlibrary:OL123W")
        #expect(saved.title == "Saved title")
        #expect(saved.pendingOperationID == operationID)
        #expect(saved.pendingOperationData == payload)
    }

    @Test func queueOrderIsIncludedInDurableSyncPayloads() async throws {
        let container = try makeContainer()
        let user = UUID()
        let transport = MockLibraryTransport(userID: user)
        let repository = LibraryRepository(userID: user, modelContext: container.mainContext, transport: transport)
        let book = makeBook()
        try repository.add(book)
        try UpNextQueue.save([book], context: container.mainContext, repository: repository)
        let payload = try JSONDecoder().decode(LibraryChange.self, from: #require(book.pendingOperationData))
        #expect(payload.readingData?.upNextPosition == 0)
        #expect(payload.readingData?.upNextExcluded == false)
        await repository.synchronize()
        #expect(book.pendingOperationID == nil)
        #expect(book.importedReading?.upNextPosition == 0)
    }

    @Test func dateAddedPersistsAndSurvivesSyncAndLaterEdits() async throws {
        let container = try makeContainer()
        let user = UUID()
        let transport = MockLibraryTransport(userID: user)
        let repository = LibraryRepository(userID: user, modelContext: container.mainContext, transport: transport)
        let book = makeBook()
        let originalDate = try #require(book.addedAt)
        try repository.add(book)
        let payload = try JSONDecoder().decode(LibraryChange.self, from: #require(book.pendingOperationData))
        #expect(payload.readingData?.libraryAddedAt == originalDate)
        await repository.synchronize()
        #expect(book.addedAt == originalDate)
        #expect(book.importedReading?.libraryAddedAt == originalDate)
        book.title = "Edited later"
        try repository.save(book)
        await repository.synchronize()
        let reopened = ModelContext(container)
        let restored = try #require(reopened.fetch(FetchDescriptor<Book>()).first)
        #expect(ArchiveSort.dateAdded(to: restored) == originalDate)
        #expect(restored.importedReading?.libraryAddedAt == originalDate)
        let reimported = UpNextQueue.metadata(for: makeBook()).preservingQueue(from: restored.importedReading)
        #expect(reimported.libraryAddedAt == originalDate)
    }

    @Test func archiveAdditionSavesEveryChosenStatusWithItsOutbox() throws {
        for status in BookAddStatus.allCases {
            let container = try makeContainer()
            let user = UUID()
            let repository = LibraryRepository(userID: user, modelContext: container.mainContext,
                                              transport: MockLibraryTransport(userID: user))
            let saved = try repository.add(makeBook(), status: status)
            let reopened = ModelContext(container)
            let book = try #require(reopened.fetch(FetchDescriptor<Book>()).first)
            let payload = try JSONDecoder().decode(LibraryChange.self, from: #require(book.pendingOperationData))
            #expect(book.id == saved.id)
            #expect(book.importedReading?.status == status.rawValue)
            #expect(payload.readingData?.status == status.rawValue)
            #expect(book.importedReading?.lastDateRead == nil)
            #expect(book.importedReading?.periods.isEmpty == true)
            if status == .read { #expect(book.importedReading?.journal?.progress?.value == 100) }
        }
    }

    @Test func readdingRemovedBookUsesChosenStatusAndPreservesItsNotes() throws {
        let container = try makeContainer()
        let user = UUID()
        let repository = LibraryRepository(userID: user, modelContext: container.mainContext,
                                          transport: MockLibraryTransport(userID: user))
        let book = try repository.add(makeBook(), status: .tbr)
        try BookReadingActions.append("Keep my note", action: .note, book: book,
                                      context: container.mainContext, repository: repository)
        try repository.remove(book)
        let restored = try repository.add(makeBook(), status: .currentlyReading)
        #expect(restored.id == book.id)
        #expect(!restored.isRemovedFromLibrary)
        #expect(restored.importedReading?.status == "currently-reading")
        #expect(restored.importedReading?.journal?.notes.first?.text == "Keep my note")
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Book>()) == 1)
    }

    @Test func addingExistingBookDoesNotOverwriteItsReadingStatus() throws {
        let container = try makeContainer()
        let user = UUID()
        let repository = LibraryRepository(userID: user, modelContext: container.mainContext,
                                          transport: MockLibraryTransport(userID: user))
        let book = try repository.add(makeBook(), status: .currentlyReading)
        let again = try repository.add(makeBook(), status: .dnf)
        #expect(again.id == book.id)
        #expect(again.importedReading?.status == "currently-reading")
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Book>()) == 1)
    }

    @Test func failedArchiveAdditionLeavesNoBookBehind() throws {
        let container = try makeContainer()
        let user = UUID()
        let repository = LibraryRepository(userID: user, modelContext: container.mainContext,
                                          transport: MockLibraryTransport(userID: user))
        repository.stop()
        #expect(throws: LibraryRepositoryError.self) { try repository.add(makeBook(), status: .read) }
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Book>()) == 0)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Book.self, Tag.self, LibrarySyncState.self])
        return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func makeBook() -> Book {
        Book(title: "Saved title", author: "Saved author", isbn: "openlibrary:OL123W",
             coverURL: "https://covers.openlibrary.org/b/id/123-M.jpg", googleBooksVolumeId: "openlibrary:OL123W")
    }
}

private actor MockLibraryTransport: LibrarySyncTransport {
    let userID: UUID
    var requests: [LibrarySyncRequest] = []
    private var offline: Bool
    private var pauseFirst: Bool
    private let conflict: Bool
    private var revision: Int64 = 0
    private var firstRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var gate: CheckedContinuation<Void, Never>?

    init(userID: UUID, offline: Bool = false, pauseFirst: Bool = false, conflict: Bool = false) {
        self.userID = userID
        self.offline = offline
        self.pauseFirst = pauseFirst
        self.conflict = conflict
    }

    func authenticatedUserID() async throws -> UUID { userID }
    func setOffline(_ value: Bool) { offline = value }

    func waitForFirstRequest() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { firstRequestWaiters.append($0) }
    }

    func release() {
        gate?.resume()
        gate = nil
    }

    func synchronize(_ request: LibrarySyncRequest) async throws -> LibrarySyncResponse {
        requests.append(request)
        firstRequestWaiters.forEach { $0.resume() }
        firstRequestWaiters.removeAll()
        if pauseFirst {
            pauseFirst = false
            await withCheckedContinuation { gate = $0 }
        }
        if offline { throw URLError(.notConnectedToInternet) }
        var results: [LibrarySyncResponse.Result] = []
        var entries: [RemoteLibraryEntry] = []
        for change in request.changes {
            revision += 1
            let source = change.book
            let snapshot = LibraryBookSnapshot(id: UUID(), provider: source.provider,
                providerID: source.providerID, title: conflict ? "Changed on another device" : source.title,
                author: source.author, isbn: source.isbn, coverURL: source.coverURL)
            let entry = RemoteLibraryEntry(id: change.entryID, bookID: snapshot.id!, revision: revision,
                updatedAt: "2026-10-08T12:00:00Z", deletedAt: change.deleted && !conflict ? "2026-10-08T12:00:00Z" : nil,
                book: snapshot, readingData: change.readingData)
            results.append(.init(operationID: change.operationID, status: conflict ? .conflict : .applied, entry: entry))
            entries.append(entry)
        }
        return LibrarySyncResponse(results: results, entries: entries,
            nextRevision: entries.last?.revision ?? request.sinceRevision, hasMore: false,
            currentRevision: max(revision, request.sinceRevision))
    }
}
