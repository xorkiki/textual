import SwiftUI
import SwiftData
import UIKit

enum DiscoverTab: String, TextualTabItem {
    case forYou, trending, explore, friends
    var id: String { rawValue }
    var identifier: String { rawValue }
    var title: String {
        switch self {
        case .forYou: return "For You"
        case .trending: return "Trending"
        case .explore: return "Explore"
        case .friends: return "Friends"
        }
    }
}

extension EnvironmentValues {
    @Entry var discoveryRepository: DiscoveryRepository? = nil
}

/// One tab's display list. A new ranking never reorders covers under the reader:
/// it waits until the tab leaves view, the app returns, or the reader pulls to refresh.
@MainActor
@Observable
final class DiscoverFeed {
    private(set) var items: [DiscoverItem] = []
    private(set) var visibleCount = 0
    /// Changes when a reordered list is adopted, so the page can return to the top.
    private(set) var generation = 0
    @ObservationIgnored private var pending: [DiscoverItem]?
    static let pageSize = 24

    var visibleItems: [DiscoverItem] { Array(items.prefix(visibleCount)) }

    func offer(_ next: [DiscoverItem]) {
        let shown = items.prefix(visibleCount).map(\.id)
        if items.isEmpty || shown.isEmpty {
            adopt(next)
        } else if next.count >= shown.count, next.prefix(shown.count).map(\.id) == shown {
            // Same covers on screen: later pages and saved state can update silently.
            items = next
            pending = nil
        } else {
            pending = next
        }
    }

    func adoptPending() {
        guard let pending else { return }
        adopt(pending)
        generation += 1
    }

    /// Reveals the next page of already-cached books.
    func loadMore() {
        guard visibleCount < items.count else { return }
        visibleCount = min(items.count, visibleCount + Self.pageSize)
    }

    private func adopt(_ next: [DiscoverItem]) {
        items = next
        pending = nil
        visibleCount = min(next.count, Self.pageSize)
    }
}

/// The Archive tab: For You, Trending, Explore, and Friends, as one continuous
/// cover grid per tab. Tap opens existing details; hold and slide uses the existing
/// quick-action menu. Cached covers appear first; refreshes run quietly behind them.
struct DiscoverView: View {
    let repository: LibraryRepository
    var isActive = true
    /// Friends' empty state routes to Community; supplied by the tab shell.
    var openCommunity: () -> Void = {}
    @Environment(\.discoveryRepository) private var discovery
    @Environment(\.socialStore) private var social
    @Environment(\.scenePhase) private var scenePhase
    @Query(filter: #Predicate<Book> { !$0.isRemovedFromLibrary }) private var books: [Book]
    @State private var selection: DiscoverTab? = .forYou
    @State private var feeds = Dictionary(uniqueKeysWithValues: DiscoverTab.allCases.map { ($0, DiscoverFeed()) })
    @State private var archive = DiscoveryArchiveIndex()
    @State private var openedBook: Book?
    @State private var route: BookActionRoute?
    @State private var saveError: String?
    @State private var displayedVersions: [DiscoveryCollection: Int] = [:]
    @State private var feedGeneration = UUID()
    private var isVisible: Bool { isActive && scenePhase == .active }
    private struct FeedTrigger: Equatable {
        let visible: Bool
        let revision: Int
    }

    /// New each session: Explore varies between visits but holds still while browsing.
    @State private var exploreSeed = UInt64.random(in: .min ... .max)

    var body: some View {
        NavigationStack {
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(DiscoverTab.allCases) { tab in
                        page(tab)
                            .containerRelativeFrame(.horizontal)
                            .id(tab)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $selection)
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .textualPageHeader { TextualTabBar(selection: $selection, identifierPrefix: "discover.tab") }
            .navigationDestination(item: $openedBook) { book in
                BookDetailView(book: book, showsReadingActivity: book.modelContext != nil)
            }
            .sheet(item: $route) { BookActionSheet(route: $0, repository: repository) }
            .alert("Couldn’t add book", isPresented: Binding(
                get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK") { saveError = nil }
            } message: { Text(saveError ?? "") }
        }
        .background {
            if let discovery {
                DiscoverForYouObserver(userID: repository.userID, discovery: discovery, isActive: isVisible)
            }
        }
        .task(id: isVisible) {
            guard isVisible else { return }
            // Refresh expiry-sensitive cached values when Home returns to view.
            await rebuildFeeds(force: true)
            guard !Task.isCancelled else { return }
            await discovery?.refreshAll()
        }
        .task(id: FeedTrigger(visible: isVisible, revision: isVisible ? (discovery?.revision ?? 0) : 0)) {
            guard isVisible else { return }
            // A remote refresh can update three collections in a short burst.
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            await rebuildFeeds()
        }
        .onChange(of: books.map(\.id), initial: true) { _, _ in
            archive = DiscoveryArchiveIndex(books: books)
            offerFriends()
        }
        .onChange(of: social?.discoveryItems) { _, _ in offerFriends() }
        .onChange(of: selection) { previous, current in
            if let previous { feeds[previous]?.adoptPending() }
            if current == .friends { Task { await social?.openDiscovery() } }
            // An empty tab checks again when opened (still subject to failure backoff).
            else if let current, feeds[current]?.items.isEmpty == true { Task { await refreshQuietly(current) } }
        }
        .onChange(of: isVisible) { _, visible in
            if !visible { feedGeneration = UUID() }
        }
        .onChange(of: isActive) { _, active in
            if !active { feeds.values.forEach { $0.adoptPending() } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { feeds.values.forEach { $0.adoptPending() } }

        }
    }

    @ViewBuilder
    private func page(_ tab: DiscoverTab) -> some View {
        if tab == .friends, let feed = feeds[.friends] {
            if let social, social.discoveryHasFriends == false {
                DiscoverFriendsEmptyPage(hasFriends: false, openCommunity: openCommunity)
            } else if let social, social.discoveryHasFriends == true, feed.items.isEmpty,
                      !social.isLoadingDiscovery, !social.discoveryFailed {
                DiscoverFriendsEmptyPage(hasFriends: true, openCommunity: openCommunity)
            } else if social == nil {
                DiscoverFriendsEmptyPage(hasFriends: false, openCommunity: openCommunity)
            } else {
                // Same grid, cells, and gestures as every other tab; pages come from the server.
                DiscoverFeedPage(feed: feed, isLoading: social?.isLoadingDiscovery == true
                                    || (social?.discoveryHasFriends == nil && social?.discoveryFailed != true),
                                 failed: social?.discoveryFailed == true,
                                 refresh: { await refreshFriends() }, retry: { Task { await refreshFriends() } },
                                 onNearEnd: { Task { await social?.loadMoreDiscovery() } }) { item, size in
                    DiscoverCoverCell(item: item, size: size, archived: archive.book(for: item),
                        open: { open(item) }, add: { add(item, status: $0) },
                        quickAction: { route = BookActionRoute(book: $0, action: $1) })
                }
                .accessibilityIdentifier("discover.page.friends")
            }
        } else if let feed = feeds[tab] {
            DiscoverFeedPage(feed: feed, isLoading: isLoading(tab), failed: hasFailed(tab),
                             attribution: tab == .trending ? attribution(feed) : nil,
                             refresh: { await refresh(tab) }, retry: { Task { await refresh(tab) } }) { item, size in
                DiscoverCoverCell(item: item, size: size, archived: archive.book(for: item),
                    open: { open(item) }, add: { add(item, status: $0) },
                    quickAction: { route = BookActionRoute(book: $0, action: $1) })
            }
            .accessibilityIdentifier("discover.page.\(tab.rawValue)")
        }
    }

    // MARK: Data

    private func rebuildFeeds(force: Bool = false) async {
        guard let discovery, isVisible, !Task.isCancelled else { return }
        let run = UUID()
        feedGeneration = run
        for (collection, tab) in [(DiscoveryCollection.trending, DiscoverTab.trending), (.forYou, .forYou)] {
            let version = discovery.collectionRevision(collection)
            if force || displayedVersions[collection] != version {
                feeds[tab]?.offer(discovery.items(collection))
                displayedVersions[collection] = version
            }
        }
        let exploreVersion = discovery.collectionRevision(.explore)
        let newVersion = discovery.collectionRevision(.newReleases)
        guard force || displayedVersions[.explore] != exploreVersion || displayedVersions[.newReleases] != newVersion else { return }
        let items = discovery.items(.explore) + discovery.items(.newReleases).map { $0.withFacet("new-releases") }
        do {
            let ordered = try await discovery.feedWorker.explore(items, seed: exploreSeed)
            try Task.checkCancellation()
            guard feedGeneration == run,
                  discovery.collectionRevision(.explore) == exploreVersion,
                  discovery.collectionRevision(.newReleases) == newVersion else { return }
            feeds[.explore]?.offer(ordered)
            displayedVersions[.explore] = exploreVersion
            displayedVersions[.newReleases] = newVersion
        } catch { /* Keep the current feed when a newer request supersedes this one. */ }
    }

    /// Friends' books outside the reader's archive (edition, ISBN, or work match),
    /// like For You. A reordered list waits until the tab leaves view or a pull.
    private func offerFriends() {
        guard let social, let feed = feeds[.friends] else { return }
        let exhausted = feed.visibleCount >= feed.items.count
        feed.offer(social.discoveryItems.filter { !archive.contains($0) })
        if exhausted { feed.loadMore() }
    }

    private func refreshFriends() async {
        await social?.refreshDiscovery()
        offerFriends()
        feeds[.friends]?.adoptPending()
    }

    private func refresh(_ tab: DiscoverTab) async {
        await discovery?.refreshAll(force: true)
        await rebuildFeeds(force: true)
        guard !Task.isCancelled else { return }
        feeds[tab]?.adoptPending()
    }

    private func refreshQuietly(_ tab: DiscoverTab) async {
        switch tab {
        case .trending: await discovery?.refresh(.trending)
        case .explore, .forYou: await discovery?.refreshAll()
        case .friends: await social?.openDiscovery()
        }
    }

    private func isLoading(_ tab: DiscoverTab) -> Bool {
        guard let discovery else { return false }
        switch tab {
        case .trending: return discovery.refreshing.contains(.trending)
        case .explore: return discovery.refreshing.contains(.explore) || discovery.refreshing.contains(.newReleases)
        case .forYou: return !discovery.refreshing.isEmpty || discovery.state(.forYou)?.fetchedAt == nil
            && !DiscoveryCollection.remote.allSatisfy { discovery.failed.contains($0) }
        case .friends: return false
        }
    }

    private func hasFailed(_ tab: DiscoverTab) -> Bool {
        guard let discovery else { return true }
        switch tab {
        case .trending: return discovery.failed.contains(.trending)
        case .explore: return discovery.failed.contains(.explore) && discovery.failed.contains(.newReleases)
        case .forYou: return DiscoveryCollection.remote.allSatisfy { discovery.failed.contains($0) }
        case .friends: return false
        }
    }

    /// NYT requires visible attribution wherever its list data shapes what is shown.
    private func attribution(_ feed: DiscoverFeed) -> String? {
        feed.items.contains { $0.sources.contains("nyt") } ? "Data provided by The New York Times" : nil
    }

    // MARK: Actions

    private func open(_ item: DiscoverItem) {
        openedBook = archive.book(for: item) ?? item.catalogBook()
    }

    /// Saves through the existing archive repository and outbox; never a second record.
    private func add(_ item: DiscoverItem, status: BookAddStatus) {
        guard archive.book(for: item) == nil else { return }
        do {
            try repository.add(item.catalogBook(), status: status)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            Task { await repository.synchronize() }
        } catch {
            saveError = "The book couldn’t be saved to your library. Please try again."
        }
    }
}

// MARK: - Pages

private struct DiscoverFeedPage<Cell: View>: View {
    let feed: DiscoverFeed
    let isLoading: Bool
    let failed: Bool
    var attribution: String?
    let refresh: () async -> Void
    let retry: () -> Void
    /// Server-paginated tabs fetch their next page here; cached tabs only reveal more.
    var onNearEnd: (() -> Void)? = nil
    @ViewBuilder let cell: (DiscoverItem, CGSize) -> Cell

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 0).id("top")
                    if feed.items.isEmpty {
                        if failed && !isLoading { unavailable } else { DiscoverPlaceholderGrid() }
                    } else {
                        MasonryGrid(items: feed.visibleItems, aspect: \.aspect,
                                    onNearEnd: { feed.loadMore(); onNearEnd?() }, cell: cell)
                        if let attribution {
                            Link(attribution, destination: URL(string: "https://developer.nytimes.com")!)
                                .font(.designSystem(.caption))
                                .foregroundStyle(Color.ghost)
                                .padding(.top, TextualLayout.pageInset)
                        }
                    }
                }
                .padding(.horizontal, TextualLayout.groupGap)
                .padding(.top, TextualLayout.contentTop)
                .padding(.bottom, TextualNavigationLayout.bottomExtent + TextualLayout.pageInset)
            }
            .scrollIndicators(.hidden)
            .refreshable { await refresh() }
            .onChange(of: feed.generation) { _, _ in proxy.scrollTo("top", anchor: .top) }
        }
    }

    /// Shown only when nothing is cached and the last refresh failed.
    private var unavailable: some View {
        VStack(spacing: TextualLayout.groupGap) {
            Text("Books couldn’t load right now.")
                .textStyle(.bodyMedium).foregroundStyle(Color.ghost)
            Button("Try again", action: retry)
                .buttonStyle(TextualButtonStyle(variant: .tonal))
                .frame(maxWidth: 200)
                .accessibilityIdentifier("discover.retry")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }
}

/// Quiet stand-ins with book-like proportions; no spinners.
private struct DiscoverPlaceholderGrid: View {
    private struct Slot: Identifiable { let id: Int; let aspect: Double }
    private let slots = [1.5, 1.35, 1.6, 1.45, 1.5, 1.4, 1.55, 1.5].enumerated().map { Slot(id: $0.offset, aspect: $0.element) }

    var body: some View {
        MasonryGrid(items: slots, aspect: \.aspect) { _, _ in
            RoundedRectangle(cornerRadius: TextualLayout.coverRadius).fill(Color.coverPlaceholder)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading books")
    }
}

/// Honest empty states: no friends yet, or friends who haven't shared any books.
private struct DiscoverFriendsEmptyPage: View {
    let hasFriends: Bool
    let openCommunity: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: TextualLayout.groupGap) {
                TextualEmptyState(title: "Nothing here yet", icon: .people,
                    detail: hasFriends ? "When your friends read, rate, and shelve books, they’ll gather here."
                                       : "When you add friends, the books they’re reading and loving will gather here.")
                    .foregroundStyle(Color.paper)
                if !hasFriends {
                    Button("Find friends", action: openCommunity)
                        .buttonStyle(TextualButtonStyle(variant: .tonal))
                        .frame(maxWidth: 200)
                        .accessibilityIdentifier("discover.friends.findFriends")
                }
            }
            .padding(.top, 96)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("discover.page.friends")
    }
}

// MARK: - Cover

private struct DiscoverCoverCell: View {
    let item: DiscoverItem
    let size: CGSize
    let archived: Book?
    let open: () -> Void
    let add: (BookAddStatus) -> Void
    let quickAction: (Book, BookQuickAction) -> Void
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // Saved books get the archive's quick actions; others get the add-to-archive statuses.
        let actions = archived == nil ? BookAddStatus.allCases.map(\.menuAction) : BookQuickAction.allCases.map(\.menuAction)
        HoldSlideSource(actions: actions, isEnabled: scenePhase == .active, open: open, select: select) {
            BookCoverImage(urlString: item.coverURL, width: size.width, height: size.height,
                identity: BookCoverIdentity(title: item.title, author: item.author,
                                            isbn: item.isbns.first ?? "", catalogID: item.catalogID),
                showsProgress: false)
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title), by \(item.author)")
        .accessibilityValue(archived == nil ? "" : "In your archive")
        .accessibilityHint(archived == nil ? "Double tap for details. Actions add it to your archive."
                                           : "Double tap for details.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .modifier(DiscoverCoverActions(archived: archived, add: add, quickAction: quickAction))
        .accessibilityIdentifier("discover.book.\(item.catalogID)")
    }

    private func select(_ id: String) {
        if let archived, let action = BookQuickAction(rawValue: id) { quickAction(archived, action) }
        else if archived == nil, let status = BookAddStatus(rawValue: id) { add(status) }
    }
}

private struct DiscoverCoverActions: ViewModifier {
    let archived: Book?
    let add: (BookAddStatus) -> Void
    let quickAction: (Book, BookQuickAction) -> Void

    func body(content: Content) -> some View {
        if let archived {
            content
                .accessibilityAction(named: "Save quote") { quickAction(archived, .quote) }
                .accessibilityAction(named: "Update progress") { quickAction(archived, .progress) }
                .accessibilityAction(named: "Finish and rate") { quickAction(archived, .finish) }
                .accessibilityAction(named: "Add note") { quickAction(archived, .note) }
        } else {
            content
                .accessibilityAction(named: "Add as read") { add(.read) }
                .accessibilityAction(named: "Add as currently reading") { add(.currentlyReading) }
                .accessibilityAction(named: "Add as to be read") { add(.tbr) }
                .accessibilityAction(named: "Add as did not finish") { add(.dnf) }
        }
    }
}

// MARK: - For You ranking

/// Re-ranks For You when taste signals or candidate pools change, debounced and
/// off the main actor. Results are cached; the visible grid adopts them later.
private struct DiscoverForYouObserver: View {
    let userID: UUID
    let discovery: DiscoveryRepository
    let isActive: Bool
    @Query(filter: #Predicate<Book> { !$0.isRemovedFromLibrary }) private var books: [Book]
    @Query private var profiles: [ReaderProfileDraft]
    @Query private var reviews: [ReaderReviewDraft]

    private struct Trigger: Equatable {
        let inputs: [DiscoveryTasteInput]
        let profile: Data?
        let pools: Int
    }

    private var trigger: Trigger? {
        // Hidden pages retain their state without decoding or ranking the library.
        guard isActive else { return nil }
        let drafts = Dictionary(reviews.filter { $0.userID == userID }.map { ($0.localBookID, $0) },
                                uniquingKeysWith: { first, _ in first })
        return Trigger(inputs: books.map { DiscoveryTasteInput(book: $0, draft: drafts[$0.id]) },
                       profile: profiles.first { $0.userID == userID }?.contentData,
                       pools: discovery.rankingInputRevision)
    }

    var body: some View {
        let input = trigger
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            .task(id: input) {
                guard let input else { return }
                do {
                    try await Task.sleep(for: .milliseconds(1500))
                    try await rank(input)
                } catch { /* Superseded work never publishes a stale ranking. */ }
            }
    }

    private func rank(_ input: Trigger) async throws {
        let taste = try await discovery.feedWorker.taste(input.inputs, profileData: input.profile)
        let authors = try await discovery.feedWorker.favoriteAuthors(taste)
        try Task.checkCancellation()
        await refreshAuthorCandidates(authors)
        try Task.checkCancellation()
        guard trigger == input else { return }
        let pools = [DiscoveryCollection.trending, .newReleases, .explore, .forYouAuthors].map {
            DiscoveryPool(collection: $0, items: discovery.items($0), fetchedAt: discovery.state($0)?.fetchedAt)
        }
        let ranked = try await discovery.feedWorker.rank(taste: taste, pools: pools,
            seed: DiscoverySeed.daily(userID: userID, date: Date()),
            previousSignature: discovery.state(.forYou)?.inputSignature,
            hasCachedResults: !discovery.items(.forYou).isEmpty)
        try Task.checkCancellation()
        guard trigger == input, let ranked else { return }
        try discovery.store(ranked.recommendations.map { ($0.item, $0.reasons) },
                            in: .forYou, signature: ranked.signature)
    }

    /// Other books by the reader's most-loved authors, looked up at most weekly and
    /// only when those authors change. Uses the shared, rate-limited catalog service.
    private func refreshAuthorCandidates(_ authors: [String]) async {
        let signature = DiscoverySeed.signature(["authors-v1"] + authors)
        let state = discovery.state(.forYouAuthors)
        if state?.inputSignature == signature, let fetched = state?.fetchedAt,
           Date().timeIntervalSince(fetched) < DiscoveryCollection.forYouAuthors.freshness { return }
        var found: [(item: DiscoverItem, reasons: [String])] = []
        for author in authors {
            guard !Task.isCancelled else { return }
            let page = try? await BookCatalogService.$isBackgroundLookup.withValue(true) {
                try await BookCatalogService.shared.searchPage(query: author, scope: .author, provider: .openLibrary)
            }
            let key = DiscoveryIdentity.authorKey(author)
            for result in (page?.items ?? []).prefix(20) {
                guard let item = Self.authorItem(result, authorKey: key) else { continue }
                found.append((item, ["author:\(author)"]))
                if found.filter({ $0.reasons == ["author:\(author)"] }).count >= 10 { break }
            }
        }
        guard !Task.isCancelled else { return }
        try? discovery.store(found, in: .forYouAuthors, signature: signature)
    }

    private static func authorItem(_ result: BookCatalogService.BookItem, authorKey: String) -> DiscoverItem? {
        guard let id = result.id, let info = result.volumeInfo, let title = info.title,
              let author = info.authors?.first(where: { DiscoveryIdentity.authorKey($0) == authorKey }),
              let thumbnail = info.imageLinks?.thumbnail, !thumbnail.isEmpty else { return nil }
        // Open Library's large rendition keeps covers sharp in a two-column grid.
        let cover = thumbnail.replacingOccurrences(of: "-M.jpg", with: "-L.jpg")
        return DiscoverItem(catalogID: id, title: title, author: author, isbns: [], coverURL: cover,
                            aspect: DiscoverItem.fallbackAspect, firstPublishedYear: nil,
                            subjects: info.categories ?? [], facet: nil, sources: [], popularity: 0, expiresAt: nil)
    }
}
