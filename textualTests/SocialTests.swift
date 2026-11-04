import Foundation
import SwiftData
import Testing
@testable import textual

// MARK: - Stats parity

struct SocialStatsParityTests {
    /// The same fixture drives the SQL port (supabase/tests/social.test.mjs).
    @Test func completedCountMatchesTheSharedDatabaseFixture() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("supabase/tests/fixtures/reading-stats.json")
        let fixture = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let base = try #require(fixture["base"] as? [String: Any])
        let cases = try #require(fixture["cases"] as? [[String: Any]])
        #expect(cases.count >= 10)
        for testCase in cases {
            let overrides = try #require(testCase["reading"] as? [String: Any])
            let merged = base.merging(overrides) { _, new in new }
            let reading = try JSONDecoder().decode(StoryGraphReadingData.self,
                                                   from: JSONSerialization.data(withJSONObject: merged))
            #expect(ReadingStatsFilter.completedCount(reading) == testCase["completed"] as? Int,
                    "\(testCase["name"] ?? "")")
        }
    }

    @Test func genreBreakdownMatchesTheCardCountAndStatsRules() {
        let evidence = [
            ReaderPersonality.Evidence(completedReads: 3, genres: ["Fantasy", "Romance"], moods: [], pace: ""),
            ReaderPersonality.Evidence(completedReads: 1, genres: ["Fantasy"], moods: [], pace: ""),
            ReaderPersonality.Evidence(completedReads: 2, genres: [], moods: [], pace: ""),
            ReaderPersonality.Evidence(completedReads: 0, genres: ["Horror"], moods: [], pace: "")
        ]
        let content = ReaderPersonality.summarize(evidence, favorites: [])
        let breakdown = content.genreBreakdown ?? []
        #expect(breakdown == [ReaderGenreShare(name: "Fantasy", books: 2, reads: 4),
                              ReaderGenreShare(name: "Romance", books: 1, reads: 3),
                              ReaderGenreShare(name: "Unclassified", books: 1, reads: 2)])
        // The card's "known genre count" equals the breakdown without the unknown bucket.
        #expect(content.stats.genres == breakdown.filter { $0.name != "Unclassified" }.count)
        #expect(breakdown.allSatisfy { ($0.reads ?? 0) >= $0.books })
    }

    @Test func visitorCardShowsHiddenStatsAsHiddenNotZero() throws {
        let json = """
        {"user_id":"00000000-0000-0000-0000-000000000002","username":"bea","first_name":"Bea","avatar_path":null,
         "member_since":"2026-10-01T00:00:00+00:00","is_owner":false,"sentence":"a little unavailable.",
         "favorites":[{"id":"6E2A1C2B-0A6F-4C1B-9E54-2F1A4D3C5B6A","title":"Emma","author":"Austen","isbn":"","coverURL":"","catalogID":"openlibrary:OL1W"}],
         "card":{"books_read":{"visible":true,"count":77,"books":77},"genres":{"visible":false},"rereads":{"visible":false}},
         "relationship":{"state":"friends","request_id":"00000000-0000-0000-0000-0000000000aa","version":2}}
        """
        let profile = try JSONDecoder().decode(VisitorProfile.self, from: Data(json.utf8))
        #expect(profile.hiddenStats == [.genres, .rereads])
        #expect(profile.cardContent.stats.reads == 77)
        #expect(profile.favorites.count == 1)
        #expect(profile.relationship?.state == .friends)
    }
}

// MARK: - Wire contract with the database

/// The same fixture is sent through the real RPCs by supabase/tests/social.test.mjs.
struct SocialWireContractTests {
    private func fixture() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("supabase/tests/fixtures/social-contract.json")
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func object(_ value: some Encodable) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? NSDictionary)
    }

    @Test func theAppEncodesExactlyWhatTheDatabaseAccepts() throws {
        let client = try #require(try fixture()["client"] as? [String: Any])
        let quoteID = try #require(UUID(uuidString: "8D4F9E63-2061-4DAC-9E5F-3C4D5E6F7081"))
        var reading = StoryGraphReadingData(sourceKey: String(repeating: "1", count: 64), status: "currently-reading",
            dateAdded: nil, lastDateRead: nil, periods: [], readCount: nil, rating: nil, format: "", moods: [], pace: "",
            tags: [], owned: nil, originalFields: [:])
        reading.journal = ReadingJournal(progress: nil, quotes: [ReadingJournal.Entry(id: quoteID, text: "A line worth keeping.",
            createdAt: Date(timeIntervalSinceReferenceDate: 0), page: 12)], notes: [])
        let intent = { (id: String, kind: SocialActivityIntent.Kind) in
            SocialActivityIntent(id: UUID(uuidString: id)!, kind: kind, shared: true, sharingVersion: 1,
                                 occurredAt: "2026-10-13T12:00:00.000Z")
        }
        var quote = intent("AF61B085-4283-4FCE-B071-5E6F708192A3", .quote)
        quote.quoteID = quoteID
        let change = LibraryChange(operationID: UUID(uuidString: "6B2D7C41-0E4F-4B8A-9C3D-1A2B3C4D5E6F")!,
            entryID: UUID(uuidString: "7C3E8D52-1F50-4C9B-8D4E-2B3C4D5E6F70")!, expectedRevision: 0, deleted: false,
            book: LibraryBookSnapshot(id: nil, provider: "openlibrary", providerID: "OL9001W", title: "Contract",
                                      author: "Writer", isbn: nil, coverURL: nil),
            readingData: reading, activity: [intent("9E50AF74-3172-4EBD-AF60-4D5E6F708192", .started), quote])
        #expect(try object(change) == client["library_change"] as? NSDictionary)

        var shelf = intent("B072C196-5394-40DF-8182-6F708192A3B4", .shelf)
        shelf.favoriteID = UUID(uuidString: "C183D2A7-64A5-41E0-9293-708192A3B4C5")
        #expect(try object(shelf) == client["shelf_intent"] as? NSDictionary)
        #expect(try object(SocialSettingsChange(activitySharing: false)) == client["settings_change"] as? NSDictionary)

        // Stamped intents use the same timestamp form the server parses.
        let stamped = SocialActivityStamp(sharingVersion: 1).intent(.started)
        #expect(stamped.occurredAt.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#, options: .regularExpression) != nil)
    }

    @Test func everyCapturedServerResponseDecodes() throws {
        let server = try #require(try fixture()["server"] as? [String: Any])
        func decode<T: Decodable>(_ type: T.Type, _ key: String) throws -> T {
            let value = try #require(server[key], "missing \(key)")
            return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value))
        }
        let feed = try decode(FeedPage.self, "feed_page")
        #expect(!feed.events.isEmpty)
        #expect(feed.events.contains { $0.kind == .quote && $0.quote?.text.isEmpty == false })
        #expect(feed.events.allSatisfy { $0.publishedDate != nil && $0.occurredDate != nil })
        let shelfAndReview = try decode(FeedPage.self, "feed_page_shelf_review")
        #expect(Set(shelfAndReview.events.map(\.kind)) == [.shelf, .review])
        #expect(shelfAndReview.events.first { $0.kind == .review }?.review?.rating != nil)
        let profile = try decode(VisitorProfile.self, "public_profile")
        #expect(profile.card?.genres.breakdown?.isEmpty == false)
        let books = try decode(ProfileBooksPage.self, "books_page")
        #expect(books.books.allSatisfy { $0.timesRead ?? 0 > 1 && $0.source == "rereads" })
        #expect(books.next != nil)
        let discovery = try decode(FriendDiscoveryPage.self, "discovery_page")
        #expect(!discovery.books.compactMap(\.item).isEmpty)
        #expect(discovery.next != nil)
        #expect(try decode(ReaderSearchPage.self, "search_page").results.first?.relationship != nil)
        let friends = try decode(FriendsPage.self, "friends_page")
        #expect(friends.friends.allSatisfy { $0.relationship?.state == .friends && $0.relationship?.requestID != nil })
        #expect(try decode(SocialSettings.self, "settings").sharingVersion >= 1)
        #expect(try decode(FriendshipResult.self, "friendship_result").relationship.state == .outgoing)
    }
}

// MARK: - Feed grouping

struct FeedGroupingTests {
    static let bea = UUID(), cleo = UUID(), emma = UUID(), dune = UUID()

    static func event(_ kind: FeedEvent.Kind, actor: UUID = bea, book: UUID = emma, hour: Int,
                      read: Int? = nil, quote: String? = nil, at published: String? = nil) -> FeedEvent {
        let stamp = published ?? String(format: "2026-10-13T%02d:00:00.123456+00:00", hour)
        return FeedEvent(id: UUID(), kind: kind, publishedAt: stamp, occurredAt: stamp,
                         readNumber: read ?? ([.started, .finished].contains(kind) ? 1 : nil),
                         actor: SocialReader(userID: actor, username: actor == bea ? "bea" : "cleo",
                                             firstName: actor == bea ? "Bea" : "Cleo", avatarPath: nil),
                         book: FeedBook(bookID: book, title: "Emma", author: "Austen", isbn: nil, coverURL: nil, catalogID: "openlibrary:OL1W"),
                         quote: quote.map { .init(text: $0, page: 3) }, review: kind == .review ? .init(rating: 18, body: "Lovely", spoilers: false) : nil)
    }

    @Test func finishingAndReviewingTheSameBookIsOneCard() {
        let groups = FeedGrouping.group([Self.event(.review, hour: 22), Self.event(.finished, hour: 21)])
        #expect(groups.count == 1)
        #expect(FeedSummary.phrase(groups[0].events) == "finished reading and reviewed it")
    }

    @Test func differentReadsAndDistantActionsNeverMerge() {
        let rereads = FeedGrouping.group([Self.event(.started, hour: 20, read: 2), Self.event(.finished, hour: 19, read: 1)])
        #expect(rereads.count == 2)
        let twoFinishes = FeedGrouping.group([Self.event(.finished, hour: 23, read: 2), Self.event(.finished, hour: 22, read: 1)])
        #expect(twoFinishes.count == 2)
        let distant = FeedGrouping.group([Self.event(.review, hour: 23), Self.event(.finished, hour: 5)])
        #expect(distant.count == 2)
        let otherReader = FeedGrouping.group([Self.event(.finished, hour: 10), Self.event(.finished, actor: Self.cleo, hour: 9)])
        #expect(otherReader.count == 2)
        let otherBook = FeedGrouping.group([Self.event(.started, hour: 10), Self.event(.started, book: Self.dune, hour: 9)])
        #expect(otherBook.count == 2)
    }

    @Test func quotesAreKeptIndividually() {
        let groups = FeedGrouping.group([Self.event(.quote, hour: 12, quote: "one"), Self.event(.quote, hour: 11, quote: "two"),
                                         Self.event(.quote, hour: 10, quote: "three")])
        #expect(groups.count == 1)
        #expect(groups[0].events.compactMap(\.quote?.text) == ["one", "two", "three"])
        #expect(FeedSummary.phrase(groups[0].events) == "saved 3 quotes")
    }

    /// Appending a page never reorders cards on screen, wherever the page boundary falls.
    @Test func groupingIsStableAcrossEveryPageBoundary() {
        let events = [Self.event(.quote, hour: 23, quote: "q"), Self.event(.started, actor: Self.cleo, book: Self.dune, hour: 22),
                      Self.event(.review, hour: 21), Self.event(.finished, hour: 20), Self.event(.started, hour: 6),
                      Self.event(.finished, actor: Self.cleo, book: Self.dune, hour: 5), Self.event(.shelf, book: Self.dune, hour: 4)]
        let whole = FeedGrouping.group(events)
        for split in 0...events.count {
            let first = FeedGrouping.group(Array(events.prefix(split)))
            let combined = FeedGrouping.append(Array(events.dropFirst(split)), to: first)
            #expect(combined == whole, "split at \(split)")
            #expect(Array(combined.prefix(first.count)).map(\.id) == first.map(\.id))
        }
        // A repeated event (overlapping pages) is ignored.
        #expect(FeedGrouping.append([events[0]], to: whole) == whole)
    }
}

// MARK: - Activity intents in the existing outbox

@MainActor
struct SocialActivityIntentTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Book.self, Tag.self, LibrarySyncState.self, ReaderProfileDraft.self, ReaderReviewDraft.self,
                             SocialSettingsState.self])
        return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func makeBook(_ id: String = "OL7W") -> Book {
        Book(title: "Emma", author: "Austen", isbn: "openlibrary:\(id)", googleBooksVolumeId: "openlibrary:\(id)")
    }

    private func intents(_ book: Book) -> [SocialActivityIntent] { SocialActivityIntent.decodeList(book.pendingActivityData) }

    private func payload(_ book: Book) throws -> LibraryChange {
        try JSONDecoder().decode(LibraryChange.self, from: #require(book.pendingOperationData))
    }

    @Test func actionsCreateNoIntentsWithoutAKnownSharingStamp() throws {
        let container = try makeContainer()
        let user = UUID()
        let repository = LibraryRepository(userID: user, modelContext: container.mainContext, transport: ActivityLibraryTransport(userID: user))
        let book = try repository.add(makeBook(), status: .currentlyReading)
        try BookReadingActions.setStatus("read", book: book, context: container.mainContext, repository: repository)
        try BookReadingActions.append("A line", page: 4, action: .quote, book: book, context: container.mainContext, repository: repository)
        #expect(book.pendingActivityData == nil)
        let change = try payload(book)
        #expect(change.activity == nil)
        // Servers without the social migration never see an "activity" key.
        let data = try #require(book.pendingOperationData)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("\"activity\""))
    }

    @Test func explicitTransitionsRideTheSameOutboxPayload() throws {
        let container = try makeContainer()
        let user = UUID()
        let repository = LibraryRepository(userID: user, modelContext: container.mainContext, transport: ActivityLibraryTransport(userID: user))
        repository.activityStamp = { SocialActivityStamp(sharingVersion: 7) }
        let context = container.mainContext
        let book = try repository.add(makeBook(), status: .currentlyReading)
        #expect(intents(book).map(\.kind) == [.started])
        try BookReadingActions.updateProgress(40, unit: .percent, book: book, context: context, repository: repository)
        try BookReadingActions.append("Private thought", action: .note, book: book, context: context, repository: repository)
        #expect(intents(book).count == 1, "progress and notes never become activity")
        try BookReadingActions.append("Badly done, Emma!", page: 12, action: .quote, book: book, context: context, repository: repository)
        let quote = try #require(book.importedReading?.journal?.quotes.first)
        try BookReadingActions.updateEntry(id: quote.id, text: "Badly done!", page: 12, action: .quote, book: book,
                                           context: context, repository: repository)
        try BookReadingActions.setStatus("read", book: book, context: context, repository: repository)
        try BookReadingActions.setStatus("read", book: book, context: context, repository: repository)
        let staged = intents(book)
        #expect(staged.map(\.kind) == [.started, .quote, .finished], "edits and repeated statuses add nothing")
        #expect(staged[1].quoteID == quote.id)
        #expect(staged.allSatisfy { $0.shared && $0.sharingVersion == 7 })
        #expect(try payload(book).activity == staged, "intents are frozen with the mutation")
        // A plain "added as read" is not evidence of finishing today.
        let read = try repository.add(makeBook("OL8W"), status: .read)
        #expect(intents(read).isEmpty)
    }

    @Test func acknowledgedIntentsAreSentOnceAndSurviveOfflineRetries() async throws {
        let container = try makeContainer()
        let user = UUID()
        let transport = ActivityLibraryTransport(userID: user, offline: true)
        let repository = LibraryRepository(userID: user, modelContext: container.mainContext, transport: transport)
        repository.activityStamp = { SocialActivityStamp(sharingVersion: 1) }
        let book = try repository.add(makeBook(), status: .currentlyReading)
        await repository.synchronize()
        #expect(intents(book).count == 1, "an offline attempt keeps the intent queued")
        await transport.setOffline(false)
        await repository.synchronize()
        #expect(book.pendingActivityData == nil)
        try BookReadingActions.updateProgress(10, unit: .page, book: book, context: container.mainContext, repository: repository)
        await repository.synchronize()
        let requests = await transport.requests
        let sent = requests.flatMap { $0.changes.compactMap(\.activity) }.flatMap { $0 }
        #expect(Set(sent.map(\.id)).count == 1, "the same intent was retried, never duplicated")
        #expect(requests.last?.changes.first?.activity == nil, "a later edit carries no old intents")
    }

    @Test func choosingTheSyncedVersionDiscardsUnsentActions() async throws {
        let container = try makeContainer()
        let user = UUID()
        let transport = ActivityLibraryTransport(userID: user, conflict: true)
        let repository = LibraryRepository(userID: user, modelContext: container.mainContext, transport: transport)
        repository.activityStamp = { SocialActivityStamp(sharingVersion: 1) }
        let book = try repository.add(makeBook(), status: .currentlyReading)
        await repository.synchronize()
        #expect(book.syncConflictData != nil)
        #expect(intents(book).count == 1, "a conflict keeps the action with the local edit")
        try repository.resolveConflictUsingServer(book)
        #expect(book.pendingActivityData == nil)
    }

    @Test func reviewsCarryAnIntentOnlyWhenNewlyShared() throws {
        let container = try makeContainer()
        let user = UUID()
        let repository = LibraryRepository(userID: user, modelContext: container.mainContext, transport: ActivityLibraryTransport(userID: user))
        let store = ReaderReviewStore(userID: user, context: container.mainContext, transport: RefusingReviewTransport(), repository: repository)
        store.activityStamp = { SocialActivityStamp(sharingVersion: 2) }
        let book = try repository.add(makeBook(), status: .read)
        book.canonicalBookID = UUID()
        var content = ReaderReviewContent(rating: 16, body: "Loved it")
        content.visibility = .private
        try store.saveDraft(content, for: book).hasLoadedRemote = true
        try store.queueSubmission(for: book)
        let privateSave = try #require(try store.draft(for: book)?.pending)
        #expect(privateSave.activity == nil)
        let encoded = String(decoding: try JSONEncoder().encode(privateSave), as: UTF8.self)
        #expect(!encoded.contains("p_activity"), "older servers receive the original parameters")

        let draft = try #require(try store.draft(for: book))
        draft.remoteData = try JSONEncoder().encode(RemoteReaderReview(workID: UUID(), bookID: book.canonicalBookID!, revision: 1,
                                                                      content: content, deleted: false))
        draft.pendingData = nil
        content.visibility = .public
        try store.saveDraft(content, for: book)
        try store.queueSubmission(for: book)
        let shared = try #require(try store.draft(for: book)?.pending)
        #expect(shared.activity?.map(\.kind) == [.review])
        #expect(store.sharesNewReviews)

        draft.remoteData = try JSONEncoder().encode(RemoteReaderReview(workID: UUID(), bookID: book.canonicalBookID!, revision: 2,
                                                                      content: content, deleted: false))
        draft.pendingData = nil
        content.body = "Loved it even more"
        try store.saveDraft(content, for: book)
        try store.queueSubmission(for: book)
        #expect(try store.draft(for: book)?.pending?.activity == nil, "editing a shared review never posts again")
    }

    @Test func shelfAdditionsPublishOnceWithTheCard() async throws {
        let container = try makeContainer()
        let user = UUID()
        let transport = ShelfTransport()
        let store = ReaderProfileStore(userID: user, context: container.mainContext, transport: transport)
        var content = ReaderPersonality.summarize([], favorites: [])
        try store.update(content)
        let favorite = ReaderFavorite(book: makeBook())
        content.favorites = [favorite]
        try store.update(content, addedFavorites: [favorite.id], stamp: SocialActivityStamp(sharingVersion: 4))
        await store.synchronize(username: "bea")
        await store.synchronize(username: "bea")
        let sent = await transport.activity
        #expect(sent.flatMap { $0 }.map(\.favoriteID) == [favorite.id])
        #expect(try store.draft()?.pendingActivityData == nil)
        // No stamp (sharing off or unknown): the shelf still saves, nothing is posted.
        content.favorites = [favorite, ReaderFavorite(book: makeBook("OL9W"))]
        try store.update(content, addedFavorites: [content.favorites[1].id], stamp: nil)
        #expect(try store.draft()?.pendingActivityData == nil)
    }
}

// MARK: - Settings and the sharing stamp

@MainActor
struct SocialSettingsStoreTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([SocialSettingsState.self])
        return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    @Test func stampExistsOnlyWhenSharingIsKnownOnAndNothingIsPending() async throws {
        let container = try makeContainer()
        let user = UUID()
        let transport = FakeSocialTransport()
        let settings = SocialSettingsStore(userID: user, context: container.mainContext, transport: transport)
        #expect(settings.stamp == nil, "unknown settings never publish")
        await settings.refresh()
        #expect(settings.stamp == SocialActivityStamp(sharingVersion: 3))

        await transport.setOffline(true)
        await settings.update(SocialSettingsChange(activitySharing: false))
        #expect(settings.settings?.activitySharing == false)
        #expect(settings.stamp == nil, "a change waiting to upload is an uncertain interval")
        await settings.update(SocialSettingsChange(activitySharing: true))
        #expect(settings.stamp == nil, "still uncertain until the server confirms")

        // The pending change survives a restart and still blocks stamping.
        let restarted = SocialSettingsStore(userID: user, context: ModelContext(container), transport: transport)
        #expect(restarted.stamp == nil)

        await transport.setOffline(false)
        await settings.refresh()
        // Off and back on never reached the server, so nothing changed there.
        #expect(settings.stamp == SocialActivityStamp(sharingVersion: 3))
        await settings.update(SocialSettingsChange(activitySharing: false))
        #expect(settings.stamp == nil)
        await settings.update(SocialSettingsChange(activitySharing: true))
        #expect(settings.stamp == SocialActivityStamp(sharingVersion: 5), "each confirmed toggle bumps the version")
        settings.stop()
        #expect(settings.stamp == nil)
    }

    /// A database with only the graph migration (or none) never receives intents.
    @Test func noStampUntilTheDatabaseVerifiesActivity() async throws {
        let container = try makeContainer()
        let transport = FakeSocialTransport()
        await transport.setActivityEnabled(nil)
        let settings = SocialSettingsStore(userID: UUID(), context: container.mainContext, transport: transport)
        await settings.refresh()
        #expect(settings.isLoaded)
        #expect(settings.stamp == nil)
        await transport.setActivityEnabled(true)
        await settings.refresh()
        #expect(settings.stamp != nil)
    }
}

// MARK: - Account-scoped social store

@MainActor
struct SocialStoreTests {
    private static var containers: [ModelContainer] = []

    private func makeStore(_ transport: FakeSocialTransport, now: @escaping () -> Date = Date.init) throws -> SocialStore {
        let schema = Schema([SocialSettingsState.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        Self.containers.append(container)
        return SocialStore(userID: UUID(), context: container.mainContext, transport: transport, now: now)
    }

    @Test func signOutDiscardsLateResponsesAndClearsFriendContent() async throws {
        let transport = FakeSocialTransport()
        await transport.setFeed([FeedGroupingTests.event(.finished, hour: 10)])
        let store = try makeStore(transport)
        await store.refreshFeed()
        #expect(store.feedGroups.count == 1)
        await transport.pauseNextFeed()
        let late = Task { await store.refreshFeed() }
        await transport.waitUntilPaused()
        store.stop()
        await transport.release()
        await late.value
        #expect(store.feedGroups.isEmpty)
        #expect(!store.feedLoaded)
        await store.refreshFeed()
        #expect(store.feedGroups.isEmpty, "a stopped store never loads again")
    }

    @Test func friendshipsShowSendingUntilTheServerConfirms() async throws {
        let transport = FakeSocialTransport()
        let store = try makeStore(transport)
        let reader = SocialReader(userID: UUID(), username: "bea", firstName: "Bea", avatarPath: nil,
                                  relationship: ReaderRelationship(state: .none))
        await transport.setSearch([reader])
        await store.search("bea")
        await transport.pauseNextFriendship()
        let sending = Task { await store.perform(.send, with: reader) }
        await transport.waitUntilPaused()
        #expect(store.pending.contains(reader.userID))
        #expect(store.searchResults.first?.relationship?.state == ReaderRelationship.State.none)
        await transport.release()
        await sending.value
        #expect(store.searchResults.first?.relationship?.state == .outgoing)
        #expect(!store.pending.contains(reader.userID))
        await transport.setFriendshipFailure(true)
        #expect(await store.perform(.send, with: reader) == false)
        #expect(store.friendsMessage != nil, "failures recover with a message, not a fake state")
    }

    @Test func feedPagesAppendAndRevalidationNeverInsertsAboveTheReader() async throws {
        let transport = FakeSocialTransport()
        let events = (0..<30).map { FeedGroupingTests.event(.started, book: UUID(), hour: 23 - $0 % 24) }
        await transport.setFeed(events)
        let store = try makeStore(transport)
        await store.refreshFeed()
        let firstPage = store.feedGroups.map(\.id)
        #expect(firstPage.count == SocialStore.feedPageSize)
        await store.loadMoreFeed()
        #expect(Array(store.feedGroups.prefix(firstPage.count)).map(\.id) == firstPage)
        #expect(store.feedGroups.count == 30)
        // A new event and a removal arrive; revalidation keeps the cutoff.
        let newer = FeedGroupingTests.event(.finished, book: UUID(), hour: 0, at: "2026-10-14T00:30:00.000000+00:00")
        await transport.setFeed([newer] + events.dropFirst())
        await store.revalidateFeed()
        #expect(!store.feedGroups.contains { $0.id == firstPage[0] }, "removed activity disappears")
        #expect(store.feedGroups.count == 29, "nothing newer than the cutoff is inserted")
        #expect(await transport.cutoffs.dropFirst().allSatisfy { $0 == FakeSocialTransport.cutoff })
    }

    @Test func expiredFriendContentIsClearedWhenItCannotBeRevalidated() async throws {
        let transport = FakeSocialTransport()
        await transport.setFeed([FeedGroupingTests.event(.finished, hour: 10)])
        var clock = Date()
        let store = try makeStore(transport, now: { clock })
        await store.refreshFeed()
        #expect(store.feedGroups.count == 1)
        await transport.setOffline(true)
        await store.revalidateFeed()
        #expect(store.feedGroups.count == 1, "recent content stays while briefly offline")
        clock = clock.addingTimeInterval(SocialStore.contentLifetime + 60)
        await store.revalidateFeed()
        #expect(store.feedGroups.isEmpty, "expired friend content is not shown indefinitely offline")
    }

    @Test func storesAreIsolatedByAccount() async throws {
        let first = FakeSocialTransport(), second = FakeSocialTransport()
        await first.setFeed([FeedGroupingTests.event(.finished, hour: 10)])
        let a = try makeStore(first), b = try makeStore(second)
        await a.refreshFeed(); await b.refreshFeed()
        #expect(a.feedGroups.count == 1)
        #expect(b.feedGroups.isEmpty)
    }

    @Test func navigationNoticeTracksRequestsAndNewFeedActivity() async throws {
        let transport = FakeSocialTransport()
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try makeStore(transport, now: { clock })
        let reader = SocialReader(userID: UUID(), username: "bea", firstName: "Bea", avatarPath: nil,
                                  relationship: ReaderRelationship(state: .incoming, requestID: UUID()))
        await transport.setIncoming([reader])
        await store.refreshIndicator()
        #expect(store.hasSocialNotice)
        await transport.setIncoming([])
        await store.refreshIndicator()
        #expect(!store.hasSocialNotice)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let newer = FeedGroupingTests.event(.finished, hour: 1,
            at: formatter.string(from: clock.addingTimeInterval(60)))
        await transport.setFeed([newer])
        await store.refreshIndicator()
        #expect(store.hasUnreadFeed)
        clock = clock.addingTimeInterval(120)
        await store.refreshFeed()
        store.markFeedSeen()
        #expect(!store.hasSocialNotice)
    }

    @Test func genrePublicationRetriesAndSkipsUnchangedEntries() async throws {
        let transport = FakeSocialTransport()
        let store = try makeStore(transport)
        let entries = [ProfileGenreEntry(entryID: UUID(), genres: ["Fantasy"])]
        await transport.setGenreFailure(true)
        #expect(await store.publishProfileGenres(entries) == false)
        await transport.setGenreFailure(false)
        #expect(await store.publishProfileGenres(entries))
        #expect(await store.publishProfileGenres(entries))
        #expect(await transport.genreUploadCount() == 1)
    }

    @Test func discoveryCursorRoundTripsAsAnExactDecimal() throws {
        let json = #"{"snapshot":"2026-10-13T06:05:01.123456+00:00","has_friends":true,"books":[{"book_id":"00000000-0000-0000-0000-000000000001","title":"Emma","author":"Austen","isbn":null,"cover_url":"https://covers.openlibrary.org/b/id/1-L.jpg","catalog_id":"openlibrary:OL1W","sources":["review","shelf"],"score":12.345678}],"next":{"score":12.345678,"book_id":"00000000-0000-0000-0000-000000000001"}}"#
        let page = try JSONDecoder().decode(FriendDiscoveryPage.self, from: Data(json.utf8))
        let encoded = String(decoding: try JSONEncoder().encode(page.next), as: UTF8.self)
        #expect(encoded.contains("12.345678"))
        let item = try #require(page.books.first?.item)
        #expect(item.catalogID == "openlibrary:OL1W")
        #expect(item.aspect == DiscoverItem.fallbackAspect)
    }
}

// MARK: - Fakes

private actor ActivityLibraryTransport: LibrarySyncTransport {
    let userID: UUID
    var requests: [LibrarySyncRequest] = []
    private var offline: Bool
    private let conflict: Bool
    private var revision: Int64 = 0

    init(userID: UUID, offline: Bool = false, conflict: Bool = false) {
        self.userID = userID; self.offline = offline; self.conflict = conflict
    }

    func setOffline(_ value: Bool) { offline = value }
    func authenticatedUserID() async throws -> UUID { userID }

    func synchronize(_ request: LibrarySyncRequest) async throws -> LibrarySyncResponse {
        requests.append(request)
        if offline { throw URLError(.notConnectedToInternet) }
        var results: [LibrarySyncResponse.Result] = []
        var entries: [RemoteLibraryEntry] = []
        for change in request.changes {
            revision += 1
            let snapshot = LibraryBookSnapshot(id: UUID(), provider: change.book.provider, providerID: change.book.providerID,
                title: change.book.title, author: change.book.author, isbn: change.book.isbn, coverURL: change.book.coverURL)
            let entry = RemoteLibraryEntry(id: change.entryID, bookID: snapshot.id!, revision: revision,
                updatedAt: "2026-10-13T12:00:00Z", deletedAt: nil, book: snapshot, readingData: change.readingData)
            results.append(.init(operationID: change.operationID, status: conflict ? .conflict : .applied, entry: entry))
            entries.append(entry)
        }
        return LibrarySyncResponse(results: results, entries: entries, nextRevision: entries.last?.revision ?? request.sinceRevision,
                                   hasMore: false, currentRevision: max(revision, request.sinceRevision))
    }
}

private struct RefusingReviewTransport: ReaderReviewTransport {
    func authenticatedUserID() async throws -> UUID { throw URLError(.notConnectedToInternet) }
    func read(userID: UUID, bookID: UUID) async throws -> RemoteReaderReview? { throw URLError(.notConnectedToInternet) }
    func submit(_ mutation: ReaderReviewMutation) async throws -> ReaderReviewResult { throw URLError(.notConnectedToInternet) }
    func summary(bookID: UUID) async throws -> CommunityReviewSummary? { nil }
    func terms() async throws -> [ReaderReviewTerm] { [] }
    func list(userID: UUID, offset: Int, limit: Int) async throws -> [RemoteReaderReview] { [] }
}

private actor ShelfTransport: ReaderProfileTransport {
    var activity: [[SocialActivityIntent]] = []
    private var published: PublicReaderProfile?

    func uploadAvatar(userID: UUID, path: String, data: Data) async throws {}
    func downloadAvatar(path: String) async throws -> Data { Data() }
    func fetch(username: String) async throws -> PublicReaderProfile? { published }
    func publish(userID: UUID, revision: Int, content: ReaderPublicContent) async throws -> PublicReaderProfile {
        try await publish(userID: userID, revision: revision, content: content, activity: [])
    }
    func publish(userID: UUID, revision: Int, content: ReaderPublicContent,
                 activity: [SocialActivityIntent]) async throws -> PublicReaderProfile {
        if !activity.isEmpty { self.activity.append(activity) }
        let profile = PublicReaderProfile(username: "bea", firstName: "Bea", memberSince: "2026-10-01",
                                          revision: revision + 1, content: content)
        published = profile
        return profile
    }
}

actor FakeSocialTransport: SocialTransport {
    static let cutoff = "2026-10-13T23:59:00.000000+00:00"
    private var settingsValue = SocialSettings(activitySharing: true, sharingVersion: 3, booksReadVisible: true,
                                               genresVisible: true, rereadsVisible: true, activityEnabled: true)
    private var offline = false
    private var feedEvents: [FeedEvent] = []
    private var searchResults: [SocialReader] = []
    private var incomingReaders: [SocialReader] = []
    private var genreUploads = 0
    private var failGenreUpload = false
    private var failFriendship = false
    private var pauseFeed = false
    private var pauseFriendship = false
    private var gate: CheckedContinuation<Void, Never>?
    private var pausedWaiters: [CheckedContinuation<Void, Never>] = []
    private var isPaused = false
    private(set) var cutoffs: [String?] = []

    func setOffline(_ value: Bool) { offline = value }
    func setActivityEnabled(_ value: Bool?) { settingsValue.activityEnabled = value }
    func setFeed(_ events: [FeedEvent]) { feedEvents = events }
    func setSearch(_ readers: [SocialReader]) { searchResults = readers }
    func setIncoming(_ readers: [SocialReader]) { incomingReaders = readers }
    func setGenreFailure(_ value: Bool) { failGenreUpload = value }
    func genreUploadCount() -> Int { genreUploads }
    func setFriendshipFailure(_ value: Bool) { failFriendship = value }
    func pauseNextFeed() { pauseFeed = true }
    func pauseNextFriendship() { pauseFriendship = true }
    func waitUntilPaused() async {
        if isPaused { return }
        await withCheckedContinuation { pausedWaiters.append($0) }
    }
    func release() { gate?.resume(); gate = nil; isPaused = false }

    private func pause() async {
        isPaused = true
        pausedWaiters.forEach { $0.resume() }
        pausedWaiters.removeAll()
        await withCheckedContinuation { gate = $0 }
    }

    func authenticatedUserID() async throws -> UUID { UUID() }
    func settings() async throws -> SocialSettings {
        if offline { throw URLError(.notConnectedToInternet) }
        return settingsValue
    }
    func updateSettings(userID: UUID, change: SocialSettingsChange) async throws -> SocialSettings {
        if offline { throw URLError(.notConnectedToInternet) }
        let updated = change.applied(to: settingsValue)
        if updated.activitySharing != settingsValue.activitySharing { settingsValue.sharingVersion += 1 }
        settingsValue = SocialSettings(activitySharing: updated.activitySharing, sharingVersion: settingsValue.sharingVersion,
                                       booksReadVisible: updated.booksReadVisible, genresVisible: updated.genresVisible,
                                       rereadsVisible: updated.rereadsVisible, activityEnabled: settingsValue.activityEnabled)
        return settingsValue
    }
    func search(query: String, after: ReaderSearchPage.Cursor?, limit: Int) async throws -> ReaderSearchPage {
        ReaderSearchPage(results: searchResults, next: nil)
    }
    func friends(after: String?, limit: Int) async throws -> FriendsPage {
        FriendsPage(friends: [], incoming: incomingReaders, outgoing: [], next: nil)
    }
    func profileFriends(username: String, after: String?, limit: Int) async throws -> ProfileFriendsPage {
        ProfileFriendsPage(friends: [], next: nil)
    }
    func publishProfileGenres(userID: UUID, entries: [ProfileGenreEntry]) async throws {
        if failGenreUpload { throw URLError(.notConnectedToInternet) }
        genreUploads += 1
    }
    func genreBooks(username: String, genre: String, after: ProfileBooksPage.Cursor?, limit: Int) async throws -> ProfileBooksPage {
        throw SocialError.forbidden
    }
    func updateFriendship(userID: UUID, operationID: UUID, action: FriendshipAction, target: UUID,
                          requestID: UUID?) async throws -> FriendshipResult {
        if pauseFriendship { pauseFriendship = false; await pause() }
        if failFriendship { throw SocialError.rateLimited }
        return FriendshipResult(outcome: "requested", relationship: ReaderRelationship(state: .outgoing, requestID: UUID()))
    }
    func profile(username: String) async throws -> VisitorProfile? { nil }
    func books(username: String, list: ProfileBookList, after: ProfileBooksPage.Cursor?, limit: Int) async throws -> ProfileBooksPage {
        throw SocialError.forbidden
    }
    func feed(cutoff: String?, before: FeedPage.Cursor?, limit: Int) async throws -> FeedPage {
        cutoffs.append(cutoff)
        if pauseFeed { pauseFeed = false; await pause() }
        if offline { throw URLError(.notConnectedToInternet) }
        // Like the server: nothing published after the session cutoff.
        let visible = feedEvents.filter { cutoff == nil || $0.publishedAt <= cutoff! }
        let start = before.flatMap { cursor in visible.firstIndex { $0.id == cursor.id }.map { $0 + 1 } } ?? 0
        let page = Array(visible.dropFirst(start).prefix(limit))
        let more = start + page.count < visible.count
        return FeedPage(cutoff: Self.cutoff, events: page,
                        next: more ? FeedPage.Cursor(publishedAt: page.last!.publishedAt, id: page.last!.id) : nil)
    }
    func discovery(snapshot: String?, after: FriendDiscoveryPage.Cursor?, limit: Int) async throws -> FriendDiscoveryPage {
        FriendDiscoveryPage(snapshot: Self.cutoff, hasFriends: false, books: [], next: nil)
    }
}
