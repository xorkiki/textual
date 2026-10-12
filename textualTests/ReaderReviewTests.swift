import Foundation
import SwiftData
import Testing
@testable import textual

private actor ReviewTestTransport: ReaderReviewTransport {
    var userID: UUID
    var remote: RemoteReaderReview?
    var requests: [ReaderReviewMutation] = []
    var failOnce = false
    var changeAccountAfterSubmit = false
    var ledger: [UUID: ReaderReviewResult] = [:]
    init(_ userID: UUID) { self.userID = userID }
    func authenticatedUserID() -> UUID { userID }
    func read(userID: UUID, bookID: UUID) -> RemoteReaderReview? { remote }
    func summary(bookID: UUID) -> CommunityReviewSummary? { nil }
    func terms() -> [ReaderReviewTerm] { [] }
    func loseNextResponse() { failOnce = true }
    func switchAfterSubmit() { changeAccountAfterSubmit = true }
    func replaceRemote(_ value: RemoteReaderReview) { remote = value }
    func submit(_ mutation: ReaderReviewMutation) throws -> ReaderReviewResult {
        requests.append(mutation)
        if let result = ledger[mutation.operationID] { return result }
        let result: ReaderReviewResult
        if (remote?.revision ?? 0) != mutation.expectedRevision {
            result = .init(status: .conflict, review: remote)
        } else {
            remote = .init(workID: mutation.bookID, bookID: mutation.bookID,
                           revision: mutation.expectedRevision + 1, content: mutation.content, deleted: mutation.deleted)
            result = .init(status: .applied, review: remote)
        }
        ledger[mutation.operationID] = result
        if changeAccountAfterSubmit { userID = UUID() }
        if failOnce { failOnce = false; throw URLError(.networkConnectionLost) }
        return result
    }
}

@MainActor
struct ReaderReviewTests {
    private func fixture() throws -> (ModelContainer, Book, UUID, ReviewTestTransport, ReaderReviewStore) {
        let schema = Schema([Book.self, Tag.self, ReaderReviewDraft.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let book = Book(title: "Book", author: "Writer", isbn: "9780140328721")
        book.canonicalBookID = UUID()
        container.mainContext.insert(book)
        try container.mainContext.save()
        let user = UUID(), transport = ReviewTestTransport(user)
        let store = ReaderReviewStore(userID: user, context: container.mainContext, transport: transport)
        return (container,book,user,transport,store)
    }

    @Test func defaultsArePrivateAndValidationRetainsOptionalChoices() throws {
        var content = ReaderReviewContent()
        #expect(content.visibility == .private && !content.contribute && content.rating == nil)
        content.moods = ["hopeful","dark","hopeful"]
        #expect(try content.validated().moods == ["dark","hopeful"])
        content.rating = 21
        #expect(throws: ReaderReviewError.self) { try content.validated() }
        content.rating = nil; content.genres = ["bad value"]
        #expect(throws: ReaderReviewError.self) { try content.validated() }
    }

    @Test func retriesAreFrozenAndDoNotPublishLaterDraftEdits() async throws {
        let (container,book,_,transport,store) = try fixture()
        _ = container
        var first = ReaderReviewContent(); first.body = "Submitted"; first.pace = .fast
        try store.saveDraft(first,for: book)
        #expect(throws: ReaderReviewError.self) { try store.queueSubmission(for: book) }
        try await store.loadRemote(for: book)
        try store.queueSubmission(for: book)
        await transport.loseNextResponse()
        do { try await store.flush(); Issue.record("Expected lost response") } catch is URLError { }
        let operation = try #require(try store.draft(for: book)?.pending?.operationID)
        var later = first; later.body = "Unsubmitted edit"; later.contribute = true
        try store.saveDraft(later,for: book)
        try await store.flush()
        let requests = await transport.requests
        #expect(requests.count == 2 && requests.allSatisfy { $0.operationID == operation })
        #expect(requests.allSatisfy { $0.content.body == "Submitted" && !$0.content.contribute })
        let draft = try #require(try store.draft(for: book))
        #expect(draft.pendingData == nil && draft.remote?.revision == 1)
        #expect(draft.content?.body == "Unsubmitted edit")
    }

    @Test func conflictsRequireExplicitResolutionAndNewSubmission() async throws {
        let (container,book,_,transport,store) = try fixture(); _ = container
        try await store.loadRemote(for: book)
        var local = ReaderReviewContent(); local.pace = .slow
        try store.saveDraft(local,for: book); try store.queueSubmission(for: book)
        let id = try #require(book.canonicalBookID)
        await transport.replaceRemote(.init(workID: id, bookID: id, revision: 1, content: .init(), deleted: false))
        try await store.flush()
        #expect(try store.draft(for: book)?.conflict != nil)
        #expect(throws: ReaderReviewError.self) { try store.queueSubmission(for: book) }
        try store.resolveConflict(for: book,keepLocal: true)
        #expect(try store.draft(for: book)?.pending == nil)
        try store.queueSubmission(for: book); try await store.flush()
        #expect(try store.draft(for: book)?.remote?.content.pace == .slow)
    }

    @Test func accountSwitchCannotApplyInFlightResponse() async throws {
        let (container,book,_,transport,store) = try fixture(); _ = container
        try await store.loadRemote(for: book); try store.queueSubmission(for: book)
        await transport.switchAfterSubmit()
        do { try await store.flush(); Issue.record("Expected account guard") } catch LibraryRepositoryError.accountChanged { }
        #expect(try store.draft(for: book)?.pending != nil)
        #expect(try store.draft(for: book)?.remote == nil)
    }

    @Test func draftsSurviveStoreReopenAndStayAccountScoped() throws {
        let (container,book,user,transport,store) = try fixture()
        var content = ReaderReviewContent(); content.body = "Offline draft"
        try store.saveDraft(content,for: book)
        let reopened = ReaderReviewStore(userID: user,context: container.mainContext,transport: transport)
        #expect(try reopened.draft(for: book)?.content == content)
        let other = ReaderReviewStore(userID: UUID(),context: container.mainContext,transport: transport)
        #expect(try other.draft(for: book) == nil)
        let outside = Book(title: "Outside",author: "Writer",isbn: "")
        #expect(throws: LibraryRepositoryError.self) { try store.saveDraft(content,for: outside) }
        store.stop()
        #expect(throws: LibraryRepositoryError.self) { try store.saveDraft(content,for: book) }
    }

    @Test func pendingSubmissionSurvivesDiskReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("reviews.store")
        let user = UUID(), bookID = UUID(), transport = ReviewTestTransport(user)
        let schema = Schema([Book.self, Tag.self, ReaderReviewDraft.self])
        let operation: UUID
        do {
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(url: url))
            let book = Book(id: bookID, title: "Saved", author: "Writer", isbn: "")
            book.canonicalBookID = UUID()
            container.mainContext.insert(book)
            let store = ReaderReviewStore(userID: user, context: container.mainContext, transport: transport)
            try await store.loadRemote(for: book)
            var content = ReaderReviewContent(); content.body = "Survives restart"
            try store.saveDraft(content, for: book)
            try store.queueSubmission(for: book)
            operation = try #require(try store.draft(for: book)?.pending?.operationID)
            store.stop()
        }
        let reopened = try ModelContainer(for: schema, configurations: ModelConfiguration(url: url))
        let book = try #require(try reopened.mainContext.fetch(FetchDescriptor<Book>()).first)
        let store = ReaderReviewStore(userID: user, context: reopened.mainContext, transport: transport)
        #expect(try store.draft(for: book)?.pending?.operationID == operation)
        #expect(try store.draft(for: book)?.content?.body == "Survives restart")
        try await store.flush()
        #expect(try store.draft(for: book)?.remote?.revision == 1)
    }

    @Test func removedLibraryBookCanStillWithdrawExistingReview() async throws {
        let (container, book, _, _, store) = try fixture(); _ = container
        try await store.loadRemote(for: book)
        try store.queueSubmission(for: book); try await store.flush()
        book.isRemovedFromLibrary = true
        #expect(throws: ReaderReviewError.self) { try store.queueSubmission(for: book) }
        try store.queueSubmission(for: book, deleted: true); try await store.flush()
        #expect(try store.draft(for: book)?.remote?.deleted == true)
        #expect(try store.draft(for: book)?.remote?.content.contribute == false)
    }

    @Test func summaryUsesRespondentsPerFieldNotSumOfMoodVotes() throws {
        let json = #"{"minimumContributors":5,"moods":{"contributors":5,"counts":{"dark":4,"tense":4}}}"#
        let summary = try JSONDecoder().decode(CommunityReviewSummary.self,from: Data(json.utf8))
        #expect(summary.moods?.fraction(for: "dark") == 0.8)
        #expect(summary.pace == nil)
    }
}
