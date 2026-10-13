import Foundation
import SwiftData
import Testing
import XCTest
import SwiftUI
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
    func list(userID: UUID, offset: Int, limit: Int) -> [RemoteReaderReview] { offset == 0 ? remote.map { [$0] } ?? [] : [] }
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

    @Test func savingReviewCompletesBookButTypingDraftDoesNot() async throws {
        let (container, book, _, _, store) = try fixture()
        try BookReadingActions.setStatus("currently-reading", book: book, context: container.mainContext, repository: nil)
        let editor = ReaderReviewEditorModel(book: book, store: store, repository: nil)
        await editor.load()
        var content = ReaderReviewContent(); content.body = "This stayed with me."
        editor.update(content)
        #expect(book.importedReading?.status == "currently-reading")
        await editor.save()
        #expect(editor.didSave)
        #expect(book.importedReading?.status == "read")
        #expect(book.importedReading?.readCount == 1)
        #expect(book.importedReading?.journal?.progress?.value == 100)
        let completed = book.importedReading
        content.body = "An edited review."
        editor.update(content)
        await editor.save()
        #expect(book.importedReading == completed)
        await editor.remove()
        #expect(book.importedReading == completed)
    }

    @Test func queuedRatingCompletesBookEvenWhenReviewResponseIsLost() async throws {
        let (container, book, _, transport, store) = try fixture()
        let editor = ReaderReviewEditorModel(book: book, store: store, repository: nil)
        await editor.load()
        var content = ReaderReviewContent(); content.rating = 0
        editor.update(content)
        await transport.loseNextResponse()
        await editor.save()
        #expect(editor.hasPending)
        let reopenedContext = ModelContext(container)
        let reopened = try #require(reopenedContext.fetch(FetchDescriptor<Book>()).first)
        #expect(reopened.importedReading?.status == "read")
        #expect(reopened.importedReading?.readCount == 1)
        await editor.retry()
        #expect(!editor.hasPending)
        #expect(book.importedReading?.readCount == 1)
    }

    @Test func reviewAndCompletedStatusShareTheDurableLibrarySave() async throws {
        let (container, book, userID, transport, _) = try fixture()
        book.googleBooksVolumeId = "reviewed-book"
        let repository = LibraryRepository(userID: userID, modelContext: container.mainContext,
            transport: ReviewLibraryTestTransport(userID: userID))
        let store = ReaderReviewStore(userID: userID, context: container.mainContext,
                                      transport: transport, repository: repository)
        try await store.loadRemote(for: book)
        var content = ReaderReviewContent(); content.body = "Reviewed from my archive."
        try store.saveDraft(content, for: book)
        try store.queueSubmission(for: book)
        let reopened = ModelContext(container)
        let savedBook = try #require(reopened.fetch(FetchDescriptor<Book>()).first)
        let savedReview = try #require(reopened.fetch(FetchDescriptor<ReaderReviewDraft>()).first)
        let change = try JSONDecoder().decode(LibraryChange.self, from: #require(savedBook.pendingOperationData))
        #expect(savedReview.pending?.content.body == content.body)
        #expect(change.readingData?.status == "read")
        #expect(savedBook.importedReading?.status == "read")
    }

    @Test func rejectedReviewSaveDoesNotCompleteBookOrQueueReview() async throws {
        let (container, book, userID, transport, _) = try fixture()
        try BookReadingActions.setStatus("currently-reading", book: book, context: container.mainContext, repository: nil)
        book.googleBooksVolumeId = "reviewed-book"
        let repository = LibraryRepository(userID: userID, modelContext: container.mainContext,
            transport: ReviewLibraryTestTransport(userID: userID))
        let store = ReaderReviewStore(userID: userID, context: container.mainContext,
                                      transport: transport, repository: repository)
        var content = ReaderReviewContent(); content.body = "A saved draft."
        try store.saveDraft(content, for: book)
        #expect(throws: ReaderReviewError.self) { try store.queueSubmission(for: book) }
        #expect(book.importedReading?.status == "currently-reading")
        try await store.loadRemote(for: book)
        repository.stop()
        #expect(throws: LibraryRepositoryError.self) { try store.queueSubmission(for: book) }
        #expect(book.importedReading?.status == "currently-reading")
        #expect(try store.draft(for: book)?.pendingData == nil)
        #expect(try store.draft(for: book)?.content?.body == content.body)
    }

    @Test func reviewsDoNotRequestOrEncodeCatalogClassification() throws {
        let legacy = #"{"version":1,"body":"","spoilers":false,"moods":[],"genres":["fantasy"],"fiction":"fiction","visibility":"private","contribute":false}"#
        let review = try JSONDecoder().decode(ReaderReviewContent.self, from: Data(legacy.utf8))
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(review)) as! [String: Any]
        #expect(encoded["genres"] == nil && encoded["fiction"] == nil)
    }

    @Test func defaultsArePrivateAndValidationRetainsOptionalChoices() throws {
        var content = ReaderReviewContent()
        #expect(content.visibility == .private && !content.contribute && content.rating == nil)
        content.moods = ["hopeful","dark","hopeful"]
        #expect(try content.validated().moods == ["dark","hopeful"])
        content.rating = 21
        #expect(throws: ReaderReviewError.self) { try content.validated() }
        content.rating = nil; content.moods = ["bad value"]
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

    @Test func editorCreatesEditsAndClearsRatingWithoutDuplicatingReview() async throws {
        let (container, book, _, transport, store) = try fixture(); _ = container
        let editor = ReaderReviewEditorModel(book: book, store: store, repository: nil)
        await editor.load()
        #expect(!editor.canSave)
        var content = ReaderReviewContent(); content.rating = 17
        editor.update(content)
        #expect(editor.canSave)
        await editor.save()
        #expect(editor.didSave && editor.draft?.remote?.revision == 1)
        #expect(editor.draft?.savedContent?.rating == 17)
        content.body = "A beautifully strange little world."; content.rating = nil; content.spoilers = true
        editor.update(content)
        #expect(editor.draft?.savedContent?.body == "")
        await editor.save()
        #expect(editor.didSave && editor.draft?.remote?.revision == 2)
        #expect(editor.draft?.savedContent?.rating == nil && editor.draft?.savedContent?.spoilers == true)
        let requests = await transport.requests
        #expect(requests.count == 2 && requests.allSatisfy { $0.expectedUserID == store.userID && $0.bookID == book.canonicalBookID })
        let reopened = ReaderReviewEditorModel(book: book, store: store, repository: nil)
        #expect(reopened.content == content)
    }

    @Test func emptyReviewIsDisabledButZeroStarsIsARealRating() async throws {
        let (container, book, _, _, store) = try fixture(); _ = container
        let editor = ReaderReviewEditorModel(book: book, store: store, repository: nil)
        var content = ReaderReviewContent(); content.body = "  \n "
        editor.update(content); #expect(!editor.canSave)
        content.rating = 0; editor.update(content); #expect(editor.canSave)
        content.body = String(repeating: "a", count: 20_001)
        editor.update(content); #expect(!editor.canSave)
        #expect(editor.draft?.content?.body == "  \n ")
    }

    @Test func remoteRefreshUpdatesCleanCacheButPreservesUnsubmittedDraft() async throws {
        let (container, book, _, transport, store) = try fixture(); _ = container
        let id = try #require(book.canonicalBookID)
        var first = ReaderReviewContent(); first.body = "First device"
        await transport.replaceRemote(.init(workID: id, bookID: id, revision: 1, content: first, deleted: false))
        try await store.refreshLibrary()
        #expect(try store.draft(for: book)?.savedContent == first)
        var newer = first; newer.rating = 18
        await transport.replaceRemote(.init(workID: id, bookID: id, revision: 2, content: newer, deleted: false))
        try await store.refreshLibrary()
        #expect(try store.draft(for: book)?.content == newer)
        #expect(try store.draft(for: book)?.conflict == nil)
        var local = newer; local.body = "My unfinished revision"
        try store.saveDraft(local, for: book)
        newer.body = "Another device edited it"
        await transport.replaceRemote(.init(workID: id, bookID: id, revision: 3, content: newer, deleted: false))
        try await store.refreshLibrary()
        #expect(try store.draft(for: book)?.content == local)
        #expect(try store.draft(for: book)?.conflict?.content == newer)
    }

    @Test func staleDownloadCannotUndoANewerAcknowledgedSave() async throws {
        let (container, book, _, transport, store) = try fixture(); _ = container
        try await store.loadRemote(for: book)
        var content = ReaderReviewContent(); content.body = "First"
        try store.saveDraft(content, for: book); try store.queueSubmission(for: book); try await store.flush()
        let older = try #require(try store.draft(for: book)?.remote)
        content.body = "Latest"
        try store.saveDraft(content, for: book); try store.queueSubmission(for: book); try await store.flush()
        await transport.replaceRemote(older)
        try await store.loadRemote(for: book)
        #expect(try store.draft(for: book)?.remote?.revision == 2)
        #expect(try store.draft(for: book)?.content?.body == "Latest")
    }

    @Test func firstOnlineLoadDoesNotOverwriteAnOfflineDraftOrExistingReview() async throws {
        let (container, book, _, transport, store) = try fixture(); _ = container
        let id = try #require(book.canonicalBookID)
        var local = ReaderReviewContent(); local.body = "Offline words"
        try store.saveDraft(local, for: book)
        var remote = local; remote.body = "Previously saved elsewhere"
        await transport.replaceRemote(.init(workID: id, bookID: id, revision: 1, content: remote, deleted: false))
        do { try await store.loadRemote(for: book); Issue.record("Expected conflict") } catch ReaderReviewError.conflict { }
        #expect(try store.draft(for: book)?.content == local)
        #expect(try store.draft(for: book)?.conflict?.content == remote)
    }

    @Test func editorRetainsQueuedReviewAfterLostResponseAndRetriesSameOperation() async throws {
        let (container, book, _, transport, store) = try fixture(); _ = container
        let editor = ReaderReviewEditorModel(book: book, store: store, repository: nil)
        await editor.load()
        var content = ReaderReviewContent(); content.body = "Keep these words."
        editor.update(content)
        await transport.loseNextResponse()
        await editor.save()
        #expect(!editor.didSave && editor.hasPending)
        #expect(editor.draft?.savedContent == content)
        await editor.retry()
        #expect(!editor.hasPending && editor.draft?.remote?.revision == 1)
        let requests = await transport.requests
        #expect(requests.count == 2 && requests[0].operationID == requests[1].operationID)
        await editor.remove()
        #expect(editor.didSave && editor.draft?.savedContent == nil && editor.content == .init())
        #expect(!book.isRemovedFromLibrary)
    }

    private func importedBook(_ book: Book, rating: String = "4.75", body: String = "A lovely review\nwith two lines.") throws {
        var row = StoryGraphImportTests.row
        row[7] = rating; row[8] = body
        let reading = try #require(StoryGraphImporter.parse(StoryGraphImportTests.csv([row])).records.first?.reading)
        book.storyGraphData = try JSONEncoder().encode(reading)
    }

    @Test func importedHTMLFromScreenshotBecomesPlainParagraphsWithSpoilerFlag() throws {
        let (container, book, _, _, store) = try fixture(); _ = container
        let raw = "<div>&lt;spoiler&gt;Daisy didn’t actually have confidence&nbsp;</div><div>She was always good</div><div>Confidence is being ok being bad</div><div>Not being ok being good</div><div>&lt;/spoiler&gt;</div>"
        try importedBook(book, body: raw)
        let source = book.storyGraphData
        let review = ReaderReviewPresentation(book: book, draft: nil)
        let content = try #require(review.content)
        #expect(content.body == "Daisy didn’t actually have confidence\n\nShe was always good\n\nConfidence is being ok being bad\n\nNot being ok being good")
        #expect(content.spoilers)
        #expect(review.editorContent == content)
        let editor = ReaderReviewEditorModel(book: book, store: store, repository: nil)
        #expect(editor.content == content)
        #expect(book.storyGraphData == source)
    }

    @Test func importedHTMLKeepsLineBreaksUnicodeAndListTextWithoutActiveContent() {
        let raw = "<p>Caf&eacute; &amp; books &#8212; &#x1F4DA;</p><p>First<br>second</p><ul><li>One</li><li>Two</li></ul><!-- hidden --><script>alert('bad')</script><style>body { color: red }</style>"
        let result = CatalogDescriptionHTML.plainReview(raw)
        #expect(result.body == "Café & books — 📚\n\nFirst\nsecond\n\n• One\n• Two")
        #expect(!result.spoilers)
        #expect(CatalogDescriptionHTML.plainReview("Plain text\nwith 3 < 5 and > 2.").body == "Plain text\nwith 3 < 5 and > 2.")
        let escaped = CatalogDescriptionHTML.plainReview("&amp;lt;div&amp;gt;&amp;lt;spoiler&amp;gt;Secret&amp;lt;/spoiler&amp;gt;&amp;lt;/div&amp;gt;")
        #expect(escaped.body == "Secret" && escaped.spoilers)
        #expect(CatalogDescriptionHTML.plainReview("<div>&nbsp;</div>").body.isEmpty)
    }

    @Test func unchangedLegacyImportCopiesDisplayCleanlyWithoutMutatingSavedData() async throws {
        let (container, book, _, _, store) = try fixture(); _ = container
        let raw = "<div>&lt;spoiler&gt;Original &amp; imported&lt;/spoiler&gt;</div>"
        try importedBook(book, body: raw)
        try await store.loadRemote(for: book)
        var legacy = ReaderReviewContent(); legacy.body = raw; legacy.rating = 19
        try store.saveDraft(legacy, for: book); try store.queueSubmission(for: book); try await store.flush()
        let draft = try #require(try store.draft(for: book))
        let review = ReaderReviewPresentation(book: book, draft: draft)
        #expect(review.content?.body == "Original & imported")
        #expect(review.content?.spoilers == true)
        #expect(!review.hasDraftChanges)
        #expect(review.editorContent.body == "Original & imported")
        #expect(draft.savedContent?.body == raw)
        var edited = legacy; edited.body = "My own <literal> text"
        try store.saveDraft(edited, for: book)
        #expect(ReaderReviewPresentation(book: book, draft: draft).editorContent.body == edited.body)
    }

    @Test func importedReviewsAppearOnceWithTextAndRatingsAndSearch() throws {
        let (container, book, user, _, _) = try fixture(); _ = container
        try importedBook(book)
        let rows = ReaderReviewPresentation.rows(books: [book], drafts: [], userID: user, search: "Writer")
        #expect(rows.count == 1)
        #expect(rows.first?.review.content?.rating == 19)
        #expect(rows.first?.review.content?.body == "A lovely review\nwith two lines.")
        #expect(rows.first?.review.isImported == true)
        #expect(rows.first?.review.content?.visibility == .private && rows.first?.review.content?.contribute == false)
        #expect(ReaderReviewPresentation.rows(books: [book], drafts: [], userID: user, search: "No match").isEmpty)
        try importedBook(book, rating: "", body: " ")
        #expect(!ReaderReviewPresentation(book: book, draft: nil).isVisible)
        try importedBook(book, rating: "0", body: "")
        #expect(ReaderReviewPresentation(book: book, draft: nil).content?.rating == 0)
        try importedBook(book, rating: "", body: "Text only")
        #expect(ReaderReviewPresentation(book: book, draft: nil).content?.body == "Text only")
    }

    @Test func importedEditorPrefillsEvenAfterDetailCreatedEmptyCache() async throws {
        let (container, book, _, transport, store) = try fixture(); _ = container
        try importedBook(book)
        let original = book.storyGraphData
        try await store.loadRemote(for: book)
        let editor = ReaderReviewEditorModel(book: book, store: store, repository: nil)
        #expect(editor.content.rating == 19 && editor.presentation.isImported)
        await editor.load()
        #expect(editor.content.body == "A lovely review\nwith two lines.")
        #expect(await transport.requests.isEmpty)
        await editor.save()
        #expect(editor.didSave && !editor.presentation.isImported)
        #expect(editor.draft?.savedContent?.rating == 19)
        #expect(book.storyGraphData == original)
    }

    @Test func clearedImportedDraftStaysClearedOnReopenAndRefresh() async throws {
        let (container, book, _, _, store) = try fixture(); _ = container
        try importedBook(book)
        let editor = ReaderReviewEditorModel(book: book, store: store, repository: nil)
        await editor.load()
        editor.update(.init())
        let reopened = ReaderReviewEditorModel(book: book, store: store, repository: nil)
        await reopened.load()
        #expect(reopened.content == .init())
        #expect(reopened.presentation.hasDraftChanges)
        #expect(reopened.presentation.content?.rating == 19)
        #expect(!reopened.canSave)
    }

    @Test func nativeEditsAndWithdrawalOverrideImportsWithoutReappearing() async throws {
        let (container, book, user, _, store) = try fixture(); _ = container
        try importedBook(book)
        let original = book.storyGraphData
        let editor = ReaderReviewEditorModel(book: book, store: store, repository: nil)
        await editor.load()
        var edited = editor.content; edited.rating = 12; edited.body = "My newer opinion"
        editor.update(edited); await editor.save()
        let draft = try #require(try store.draft(for: book))
        let rows = ReaderReviewPresentation.rows(books: [book], drafts: [draft], userID: user, search: "")
        #expect(rows.count == 1 && rows.first?.review.content == edited)
        await editor.remove()
        #expect(!ReaderReviewPresentation(book: book, draft: draft).isVisible)
        #expect(book.storyGraphData == original)
        #expect(!book.isRemovedFromLibrary)
        let reopened = ReaderReviewEditorModel(book: book, store: store, repository: nil)
        #expect(reopened.content == .init())
    }

    @Test func importedReviewCanBeWithdrawnWithoutSavingItFirst() async throws {
        let (container, book, _, _, store) = try fixture(); _ = container
        try importedBook(book)
        let editor = ReaderReviewEditorModel(book: book, store: store, repository: nil)
        await editor.load(); await editor.remove()
        #expect(editor.didSave)
        #expect(editor.draft?.remote?.deleted == true)
        #expect(editor.presentation.content == nil)
        #expect(book.importedReading?.rating == 4.75)
    }

    @Test func summaryUsesRespondentsPerFieldNotSumOfMoodVotes() throws {
        let json = #"{"minimumContributors":5,"moods":{"contributors":5,"counts":{"dark":4,"tense":4}}}"#
        let summary = try JSONDecoder().decode(CommunityReviewSummary.self,from: Data(json.utf8))
        #expect(summary.moods?.fraction(for: "dark") == 0.8)
        #expect(summary.pace == nil)
    }
}

@MainActor
final class ReaderReviewRenderingTests: XCTestCase {
    func testEditorAndSavedReviewAtPhoneAndAccessibilitySizes() throws {
        let container = try ModelContainer(for: Book.self, Tag.self, ReaderReviewDraft.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let user = UUID()
        let book = Book(title: "The Secret History", author: "Donna Tartt", isbn: "")
        book.canonicalBookID = UUID()
        container.mainContext.insert(book)
        let store = ReaderReviewStore(userID: user, context: container.mainContext, transport: ReviewTestTransport(user))
        var content = ReaderReviewContent(); content.rating = 17
        content.body = "Beautiful, unsettling, and impossible to put down. The atmosphere stayed with me long after the last page."
        try store.saveDraft(content, for: book)
        for (width, size, name) in [(390.0, DynamicTypeSize.large, "Review editor"), (320.0, .accessibility3, "Review editor large text")] {
            let root = ReaderReviewEditor(book: book, store: store)
                .modelContainer(container).textualScreenDefaults().environment(\.dynamicTypeSize, size)
            let controller = UIHostingController(rootView: root)
            let bounds = CGRect(x: 0, y: 0, width: width, height: 844)
            let window = UIWindow(frame: bounds)
            window.rootViewController = controller; window.isHidden = false
            controller.view.frame = bounds
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in
                controller.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertEqual(image.size.width, width)
            window.isHidden = true
        }
    }
}

private actor ReviewLibraryTestTransport: LibrarySyncTransport {
    let userID: UUID
    init(userID: UUID) { self.userID = userID }
    func authenticatedUserID() async throws -> UUID { userID }
    func synchronize(_ request: LibrarySyncRequest) async throws -> LibrarySyncResponse { throw URLError(.notConnectedToInternet) }
}
