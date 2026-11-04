import Foundation
import Observation
import SwiftData
import SwiftUI

extension EnvironmentValues {
    @Entry var socialStore: SocialStore? = nil
}

/// The owner's privacy settings. Server values and any change waiting to upload
/// persist in the account store. New activity is stamped only when sharing is
/// known to be on; while a change is pending (an uncertain interval) nothing is.
@MainActor
@Observable
final class SocialSettingsStore {
    /// Effective settings shown in the UI: server values with pending changes applied.
    private(set) var settings: SocialSettings?
    private(set) var stamp: SocialActivityStamp?
    private(set) var isSaving = false
    private(set) var message: String?
    @ObservationIgnored private let userID: UUID
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let transport: any SocialTransport
    @ObservationIgnored private var active = true
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Called after a settings change reaches the server (caches depend on it).
    @ObservationIgnored var onChange: (() -> Void)?

    init(userID: UUID, context: ModelContext, transport: any SocialTransport) {
        self.userID = userID
        self.context = context
        self.transport = transport
        recompute()
    }

    var isLoaded: Bool { settings != nil }

    func stop() {
        active = false
        refreshTask?.cancel()
        refreshTask = nil
        stamp = nil
    }

    /// Uploads any pending change, then reads the server's settings. Coalesced.
    func refresh() async {
        guard active else { return }
        if let refreshTask { return await refreshTask.value }
        let task = Task { await self.performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    func update(_ change: SocialSettingsChange) async {
        guard active else { return }
        do {
            let state = try stateRow()
            let merged = change.merged(over: state.pending)
            state.pendingData = try JSONEncoder().encode(merged)
            try context.save()
            message = nil
        } catch {
            context.rollback()
            message = "Your privacy settings couldn’t be saved. Please try again."
        }
        recompute()
        await refresh()
    }

    private func performRefresh() async {
        do {
            let state = try stateRow()
            if let pending = state.pending, let sent = state.pendingData {
                isSaving = true
                defer { isSaving = false }
                let saved = try await transport.updateSettings(userID: userID, change: pending)
                guard active else { return }
                // A change made while this request was in flight stays pending.
                if state.pendingData == sent { state.pendingData = nil }
                state.serverData = try JSONEncoder().encode(saved)
                state.loadedAt = Date()
                try context.save()
                recompute()
                onChange?()
                if state.pendingData != nil { return await performRefresh() }
            } else {
                let saved = try await transport.settings()
                guard active else { return }
                let changed = state.server != saved
                state.serverData = try JSONEncoder().encode(saved)
                state.loadedAt = Date()
                try context.save()
                recompute()
                if changed { onChange?() }
            }
            message = nil
        } catch is CancellationError {
        } catch {
            guard active else { return }
            message = settings == nil ? nil : "Saved on this iPhone. Your privacy settings couldn’t update yet."
            recompute()
        }
    }

    private func stateRow() throws -> SocialSettingsState {
        let id = userID
        if let row = try context.fetch(FetchDescriptor<SocialSettingsState>(predicate: #Predicate { $0.userID == id })).first {
            return row
        }
        let row = SocialSettingsState(userID: userID)
        context.insert(row)
        return row
    }

    private func recompute() {
        let id = userID
        let row = try? context.fetch(FetchDescriptor<SocialSettingsState>(predicate: #Predicate { $0.userID == id })).first
        let server = row?.server
        let pending = row?.pending
        settings = server.map { pending?.applied(to: $0) ?? $0 }
        if active, let server, pending == nil, row?.loadedAt != nil, server.activitySharing, server.activityEnabled == true {
            stamp = SocialActivityStamp(sharingVersion: server.sharingVersion)
        } else {
            stamp = nil
        }
    }
}

/// Account-scoped social state. Friend content is memory-only and bounded; nothing
/// here is written to SwiftData, so it can never enter the viewer's archive, Stats,
/// or editing queries. stop() clears everything and discards late responses.
@MainActor
@Observable
final class SocialStore {
    let userID: UUID
    let settings: SocialSettingsStore
    @ObservationIgnored let transport: any SocialTransport
    @ObservationIgnored let avatarTransport: (any ReaderAvatarTransport)?

    // Friends and requests (server-confirmed).
    private(set) var friends: [SocialReader] = []
    private(set) var incoming: [SocialReader] = []
    private(set) var outgoing: [SocialReader] = []
    private(set) var friendsLoaded = false
    private(set) var friendsMessage: String?
    private(set) var pendingRequestNotice = false
    private(set) var hasUnreadFeed = false
    var hasSocialNotice: Bool { pendingRequestNotice || hasUnreadFeed }
    /// Readers with a friendship change in flight ("sending"); never shown as friends early.
    private(set) var pending: Set<UUID> = []

    // Search.
    private(set) var searchQuery = ""
    private(set) var searchResults: [SocialReader] = []
    private(set) var searchHasMore = false
    private(set) var isSearching = false
    private(set) var searchMessage: String?
    @ObservationIgnored private var searchNext: ReaderSearchPage.Cursor?

    // Feed.
    private(set) var feedGroups: [FeedGroup] = []
    private(set) var feedLoaded = false
    private(set) var feedHasMore = false
    private(set) var isLoadingFeed = false
    private(set) var feedMessage: String?
    @ObservationIgnored private var feedEvents: [FeedEvent] = []
    @ObservationIgnored private var feedCutoff: String?
    @ObservationIgnored private var feedNext: FeedPage.Cursor?
    @ObservationIgnored private var feedLoadedAt: Date?
    @ObservationIgnored private var feedStale = false

    // Discover → Friends.
    private(set) var discoveryItems: [DiscoverItem] = []
    private(set) var discoveryHasFriends: Bool?
    private(set) var discoveryHasMore = false
    private(set) var isLoadingDiscovery = false
    private(set) var discoveryFailed = false
    @ObservationIgnored private var discoverySnapshot: String?
    @ObservationIgnored private var discoveryNext: FriendDiscoveryPage.Cursor?
    @ObservationIgnored private var discoveryLoadedAt: Date?
    @ObservationIgnored private var discoveryStale = false

    // Visitor profiles: small LRU with a short lifetime.
    @ObservationIgnored private var profiles: [String: (profile: VisitorProfile, loadedAt: Date)] = [:]
    @ObservationIgnored private var profileOrder: [String] = []
    @ObservationIgnored private var profileRequests: [String: Task<VisitorProfile?, Error>] = [:]

    @ObservationIgnored private var active = true
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var friendsTask: Task<Void, Never>?
    @ObservationIgnored private var uploadedProfileGenres: [ProfileGenreEntry]?
    @ObservationIgnored private var profileGenreTask: Task<Bool, Never>?
    @ObservationIgnored private var indicatorTask: Task<Void, Never>?
    @ObservationIgnored private var latestNoticeDate: Date?
    @ObservationIgnored private let noticeDefaults = UserDefaults.standard
    /// Published card photos for rows and the feed; bounded and cleared with the account.
    @ObservationIgnored private let avatars: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 50
        return cache
    }()

    static let feedPageSize = 25
    static let maximumFeedEvents = 500
    static let discoveryPageSize = 24
    static let maximumDiscoveryItems = 240
    static let profileLifetime: TimeInterval = 5 * 60
    static let maximumProfiles = 20
    /// Friend content older than this is cleared rather than shown when it can't be revalidated.
    static let contentLifetime: TimeInterval = 60 * 60

    init(userID: UUID, context: ModelContext, transport: any SocialTransport,
         avatarTransport: (any ReaderAvatarTransport)? = nil, now: @escaping () -> Date = Date.init) {
        self.userID = userID
        self.transport = transport
        self.avatarTransport = avatarTransport
        self.now = now
        settings = SocialSettingsStore(userID: userID, context: context, transport: transport)
        settings.onChange = { [weak self] in self?.invalidateOwnProfile() }
    }

    var isActive: Bool { active }

    /// Sign-out or account switch: cancel work, forget friend content, ignore late replies.
    func stop() {
        active = false
        generation = UUID()
        settings.stop()
        friendsTask?.cancel()
        profileGenreTask?.cancel()
        indicatorTask?.cancel()
        profileRequests.values.forEach { $0.cancel() }
        profileRequests = [:]
        profiles = [:]
        profileOrder = []
        avatars.removeAllObjects()
        friends = []; incoming = []; outgoing = []; friendsLoaded = false; pending = []
        pendingRequestNotice = false; hasUnreadFeed = false; latestNoticeDate = nil
        searchQuery = ""; searchResults = []; searchNext = nil; searchHasMore = false
        resetFeed()
        resetDiscovery()
    }

    /// Foreground/open: confirm settings and friendships, and revalidate shown content.
    func revalidate() async {
        guard active else { return }
        await settings.refresh()
        await reloadFriends()
        if feedLoaded { await revalidateFeed() }
        if discoveryHasFriends != nil { await revalidateDiscovery() }
        await refreshIndicator()
    }

    // MARK: Friends

    func reloadFriends() async {
        guard active else { return }
        if let friendsTask { return await friendsTask.value }
        let run = generation
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                // The first page carries pending requests. Bounded: at most five pages (1,000 friends).
                let first = try await self.transport.friends(after: nil, limit: 200)
                var page = first
                var all = page.friends
                for _ in 0..<4 where page.next != nil {
                    page = try await self.transport.friends(after: page.next, limit: 200)
                    all += page.friends
                }
                guard self.isCurrent(run) else { return }
                self.friends = all
                self.incoming = first.incoming
                self.pendingRequestNotice = !first.incoming.isEmpty
                self.outgoing = first.outgoing
                self.friendsLoaded = true
                self.friendsMessage = nil
            } catch {
                guard self.isCurrent(run), !(error is CancellationError) else { return }
                self.friendsMessage = (error as? SocialError)?.errorDescription ?? SocialError.unavailable.errorDescription
            }
        }
        friendsTask = task
        await task.value
        if isCurrent(run) { friendsTask = nil }
    }

    /// A one-row probe on launch/foreground avoids loading the entire social
    /// graph or feed just to decide whether the navigation dot should appear.
    func refreshIndicator() async {
        guard active else { return }
        if let indicatorTask { return await indicatorTask.value }
        let run = generation
        let task = Task { await self.performIndicatorRefresh(run: run) }
        indicatorTask = task
        await task.value
        if isCurrent(run) { indicatorTask = nil }
    }

    private func performIndicatorRefresh(run: UUID) async {
        async let requests = transport.friends(after: nil, limit: 1)
        async let recent = transport.feed(cutoff: nil, before: nil, limit: 1)
        let requestPage = try? await requests
        let feedPage = try? await recent
        guard isCurrent(run) else { return }
        if let requestPage { pendingRequestNotice = !requestPage.incoming.isEmpty }
        let key = "textual.social.lastSeenFeed.\(userID.uuidString)"
        if let feedPage {
            latestNoticeDate = feedPage.events.first?.publishedDate
            if let seen = noticeDefaults.object(forKey: key) as? Double,
               let latest = feedPage.events.first?.publishedDate {
                hasUnreadFeed = latest.timeIntervalSince1970 > seen
            } else if noticeDefaults.object(forKey: key) == nil {
                noticeDefaults.set(now().timeIntervalSince1970, forKey: key)
                hasUnreadFeed = false
            } else {
                hasUnreadFeed = false
            }
        }
    }

    func markFeedSeen() {
        guard active, feedLoaded else { return }
        let key = "textual.social.lastSeenFeed.\(userID.uuidString)"
        guard let loadedThrough = feedEvents.compactMap(\.publishedDate).max()
                ?? feedCutoff.flatMap(DiscoveryDate.parse) else { return }
        let seen = max(noticeDefaults.double(forKey: key), loadedThrough.timeIntervalSince1970)
        noticeDefaults.set(seen, forKey: key)
        hasUnreadFeed = latestNoticeDate.map { $0.timeIntervalSince1970 > seen } ?? false
    }

    /// Server-confirmed: the UI shows "sending" until the server answers.
    @discardableResult
    func perform(_ action: FriendshipAction, with reader: SocialReader) async -> Bool {
        guard active, !pending.contains(reader.userID) else { return false }
        let run = generation
        pending.insert(reader.userID)
        defer { if isCurrent(run) { pending.remove(reader.userID) } }
        do {
            let result = try await transport.updateFriendship(userID: userID, operationID: UUID(), action: action,
                target: reader.userID, requestID: action == .send ? nil : reader.relationship?.requestID)
            guard isCurrent(run) else { return false }
            apply(result.relationship, to: reader.userID)
            profiles[reader.username] = nil
            if [.accept, .remove].contains(action) || result.relationship.state == .friends {
                feedStale = true
                discoveryStale = true
            }
            friendsMessage = nil
            await reloadFriends()
            return true
        } catch {
            guard isCurrent(run) else { return false }
            // Show the server's real state, then explain why the change didn't happen.
            await reloadFriends()
            friendsMessage = (error as? SocialError)?.errorDescription ?? SocialError.unavailable.errorDescription
            return false
        }
    }

    private func apply(_ relationship: ReaderRelationship, to reader: UUID) {
        searchResults = searchResults.map { var copy = $0; if copy.userID == reader { copy.relationship = relationship }; return copy }
        if let cached = profiles.first(where: { $0.value.profile.userID == reader })?.key { profiles[cached] = nil }
    }

    // MARK: Search

    /// Debounce lives in the view (task per query, cancelled on change); every
    /// response is checked against the latest query before it is shown.
    func search(_ query: String) async {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        searchQuery = normalized
        searchNext = nil
        guard active, normalized.trimmingCharacters(in: CharacterSet(charactersIn: "@")).count >= 2 else {
            searchResults = []; searchHasMore = false; isSearching = false; searchMessage = nil
            return
        }
        await loadSearchPage(normalized, after: nil)
    }

    func loadMoreSearch() async {
        guard active, !isSearching, let next = searchNext else { return }
        await loadSearchPage(searchQuery, after: next)
    }

    private func loadSearchPage(_ query: String, after: ReaderSearchPage.Cursor?) async {
        let run = generation
        isSearching = true
        defer { if isCurrent(run) && searchQuery == query { isSearching = false } }
        do {
            let page = try await transport.search(query: query, after: after, limit: 20)
            try Task.checkCancellation()
            guard isCurrent(run), searchQuery == query else { return }
            searchResults = after == nil ? page.results : searchResults + page.results.filter { result in
                !searchResults.contains { $0.userID == result.userID } }
            searchNext = page.next
            searchHasMore = page.next != nil
            searchMessage = nil
        } catch is CancellationError {
        } catch {
            guard isCurrent(run), searchQuery == query else { return }
            searchMessage = (error as? SocialError)?.errorDescription ?? SocialError.unavailable.errorDescription
        }
    }

    // MARK: Profiles

    func cachedProfile(_ username: String) -> VisitorProfile? {
        guard let entry = profiles[username], now().timeIntervalSince(entry.loadedAt) < Self.profileLifetime else { return nil }
        return entry.profile
    }

    /// Reads a reader's card through the permission-filtered endpoint. Coalesced per username.
    func loadProfile(_ username: String, force: Bool = false) async throws -> VisitorProfile? {
        guard active else { throw SocialError.accountChanged }
        if !force, let cached = cachedProfile(username) { return cached }
        if let request = profileRequests[username] { return try await request.value }
        let run = generation
        let request = Task { try await transport.profile(username: username) }
        profileRequests[username] = request
        defer { if isCurrent(run) { profileRequests[username] = nil } }
        let profile = try await request.value
        guard isCurrent(run) else { throw SocialError.accountChanged }
        if let profile {
            profiles[username] = (profile, now())
            profileOrder.removeAll { $0 == username }
            profileOrder.append(username)
            while profileOrder.count > Self.maximumProfiles { profiles[profileOrder.removeFirst()] = nil }
        } else {
            profiles[username] = nil
        }
        return profile
    }

    /// One permitted page; permission is rechecked by the server on every call.
    func books(username: String, list: ProfileBookList, after: ProfileBooksPage.Cursor?) async throws -> ProfileBooksPage {
        guard active else { throw SocialError.accountChanged }
        let run = generation
        do {
            let page = try await transport.books(username: username, list: list, after: after, limit: 30)
            guard isCurrent(run) else { throw SocialError.accountChanged }
            return page
        } catch SocialError.forbidden {
            // Server-reported revocation: the cached card may be out of date.
            profiles[username] = nil
            throw SocialError.forbidden
        }
    }

    func profileFriends(username: String, after: String?, limit: Int = 40) async throws -> ProfileFriendsPage {
        guard active else { throw SocialError.accountChanged }
        let run = generation
        let page = try await transport.profileFriends(username: username, after: after, limit: limit)
        guard isCurrent(run) else { throw SocialError.accountChanged }
        return page
    }

    @discardableResult
    func publishProfileGenres(_ entries: [ProfileGenreEntry]) async -> Bool {
        guard active else { return false }
        if uploadedProfileGenres == entries { return true }
        if let profileGenreTask {
            _ = await profileGenreTask.value
            guard active else { return false }
            if uploadedProfileGenres == entries { return true }
        }
        let run = generation
        let task = Task {
            do {
                try await transport.publishProfileGenres(userID: userID, entries: entries)
                guard isCurrent(run) else { return false }
                uploadedProfileGenres = entries
                return true
            } catch {
                // A later profile sync retries; never block the card or local archive.
                return false
            }
        }
        profileGenreTask = task
        let success = await task.value
        if isCurrent(run) { profileGenreTask = nil }
        return success
    }

    func genreBooks(username: String, genre: String, after: ProfileBooksPage.Cursor?) async throws -> ProfileBooksPage {
        guard active else { throw SocialError.accountChanged }
        let run = generation
        let page = try await transport.genreBooks(username: username, genre: genre, after: after, limit: 30)
        guard isCurrent(run) else { throw SocialError.accountChanged }
        return page
    }

    func avatarData(path: String) async -> Data? {
        if let cached = avatars.object(forKey: path as NSString) { return cached as Data }
        guard active, let avatarTransport, ReaderAvatar.isValid(path: path) else { return nil }
        let run = generation
        guard let data = try? await avatarTransport.downloadAvatar(path: path), isCurrent(run) else { return nil }
        avatars.setObject(data as NSData, forKey: path as NSString)
        return data
    }

    private func invalidateOwnProfile() {
        profiles = profiles.filter { $0.value.profile.userID != userID }
    }

    // MARK: Feed

    /// New browsing session: a fresh cutoff, first page only.
    func refreshFeed() async {
        guard active, !isLoadingFeed else { return }
        let run = generation
        isLoadingFeed = true
        defer { if isCurrent(run) { isLoadingFeed = false } }
        do {
            let page = try await transport.feed(cutoff: nil, before: nil, limit: Self.feedPageSize)
            guard isCurrent(run) else { return }
            feedCutoff = page.cutoff
            feedEvents = page.events
            feedNext = page.next
            feedGroups = FeedGrouping.group(page.events)
            feedHasMore = page.next != nil
            feedLoaded = true
            feedLoadedAt = now()
            feedStale = false
            feedMessage = nil
        } catch {
            guard isCurrent(run), !(error is CancellationError) else { return }
            expireFeedIfNeeded()
            feedMessage = (error as? SocialError)?.errorDescription ?? SocialError.unavailable.errorDescription
        }
    }

    /// Loads the first page if needed, or starts a new session after a friendship change.
    func openFeed() async {
        if !feedLoaded || feedStale { await refreshFeed() }
    }

    func loadMoreFeed() async {
        guard active, !isLoadingFeed, let next = feedNext, let cutoff = feedCutoff,
              feedEvents.count < Self.maximumFeedEvents else { return }
        let run = generation
        isLoadingFeed = true
        defer { if isCurrent(run) { isLoadingFeed = false } }
        do {
            let page = try await transport.feed(cutoff: cutoff, before: next, limit: Self.feedPageSize)
            guard isCurrent(run), feedCutoff == cutoff else { return }
            let fresh = page.events.filter { event in !feedEvents.contains { $0.id == event.id } }
            feedEvents += fresh
            feedGroups = FeedGrouping.append(fresh, to: feedGroups)
            feedNext = page.next
            feedHasMore = page.next != nil && feedEvents.count < Self.maximumFeedEvents
            feedMessage = nil
        } catch {
            guard isCurrent(run), !(error is CancellationError) else { return }
            feedMessage = (error as? SocialError)?.errorDescription ?? SocialError.unavailable.errorDescription
        }
    }

    /// Same cutoff, same depth: removed or revoked events disappear, nothing new is
    /// inserted above the reader, and unchanged cards keep their positions.
    func revalidateFeed() async {
        guard active, feedLoaded, !isLoadingFeed, let cutoff = feedCutoff else { return }
        if feedStale { return await refreshFeed() }
        let run = generation
        let depth = max(feedEvents.count, Self.feedPageSize)
        isLoadingFeed = true
        defer { if isCurrent(run) { isLoadingFeed = false } }
        do {
            var events: [FeedEvent] = []
            var cursor: FeedPage.Cursor?
            repeat {
                let page = try await transport.feed(cutoff: cutoff, before: cursor, limit: 50)
                guard isCurrent(run) else { return }
                events += page.events
                cursor = page.next
            } while cursor != nil && events.count < depth
            feedEvents = events
            feedNext = cursor
            feedGroups = FeedGrouping.group(events)
            feedHasMore = cursor != nil
            feedLoadedAt = now()
            feedMessage = nil
        } catch {
            guard isCurrent(run), !(error is CancellationError) else { return }
            expireFeedIfNeeded()
        }
    }

    private func expireFeedIfNeeded() {
        if let loaded = feedLoadedAt, now().timeIntervalSince(loaded) > Self.contentLifetime { resetFeed() }
    }

    private func resetFeed() {
        feedGroups = []; feedEvents = []; feedCutoff = nil; feedNext = nil
        feedLoaded = false; feedHasMore = false; feedLoadedAt = nil; feedStale = false
    }

    // MARK: Discover → Friends

    func refreshDiscovery() async {
        guard active, !isLoadingDiscovery else { return }
        let run = generation
        isLoadingDiscovery = true
        defer { if isCurrent(run) { isLoadingDiscovery = false } }
        do {
            let page = try await transport.discovery(snapshot: nil, after: nil, limit: Self.discoveryPageSize)
            guard isCurrent(run) else { return }
            discoverySnapshot = page.snapshot
            discoveryItems = Self.unique(page.books.compactMap(\.item))
            discoveryNext = page.next
            discoveryHasMore = page.next != nil
            discoveryHasFriends = page.hasFriends
            discoveryLoadedAt = now()
            discoveryStale = false
            discoveryFailed = false
        } catch {
            guard isCurrent(run), !(error is CancellationError) else { return }
            if let loaded = discoveryLoadedAt, now().timeIntervalSince(loaded) > Self.contentLifetime { resetDiscovery() }
            discoveryFailed = true
        }
    }

    func openDiscovery() async {
        if discoveryHasFriends == nil || discoveryStale { await refreshDiscovery() }
    }

    func loadMoreDiscovery() async {
        guard active, !isLoadingDiscovery, let next = discoveryNext, let snapshot = discoverySnapshot,
              discoveryItems.count < Self.maximumDiscoveryItems else { return }
        let run = generation
        isLoadingDiscovery = true
        defer { if isCurrent(run) { isLoadingDiscovery = false } }
        do {
            let page = try await transport.discovery(snapshot: snapshot, after: next, limit: Self.discoveryPageSize)
            guard isCurrent(run), discoverySnapshot == snapshot else { return }
            discoveryItems = Self.unique(discoveryItems + page.books.compactMap(\.item))
            discoveryNext = page.next
            discoveryHasMore = page.next != nil && discoveryItems.count < Self.maximumDiscoveryItems
            discoveryFailed = false
        } catch {
            guard isCurrent(run), !(error is CancellationError) else { return }
            discoveryFailed = true
        }
    }

    private func revalidateDiscovery() async {
        if let loaded = discoveryLoadedAt, now().timeIntervalSince(loaded) < 5 * 60, !discoveryStale { return }
        await refreshDiscovery()
    }

    private func resetDiscovery() {
        discoveryItems = []; discoverySnapshot = nil; discoveryNext = nil; discoveryHasMore = false
        discoveryHasFriends = nil; discoveryLoadedAt = nil; discoveryStale = false; discoveryFailed = false
    }

    /// Existing book identity rules: one cover per catalog ID.
    private static func unique(_ items: [DiscoverItem]) -> [DiscoverItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.catalogID).inserted }
    }

    private func isCurrent(_ run: UUID) -> Bool { active && generation == run }
}
