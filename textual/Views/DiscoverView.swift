import SwiftUI
import SwiftData
import UIKit

enum DiscoverTab: String, CaseIterable, Identifiable {
    case forYou, trending, explore, friends
    var id: String { rawValue }
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
    @Environment(\.discoveryRepository) private var discovery
    @Environment(\.scenePhase) private var scenePhase
    @Query(filter: #Predicate<Book> { !$0.isRemovedFromLibrary }) private var books: [Book]
    @State private var selection: DiscoverTab? = .forYou
    @State private var feeds = Dictionary(uniqueKeysWithValues: DiscoverTab.allCases.map { ($0, DiscoverFeed()) })
    @State private var archive = DiscoveryArchiveIndex()
    @State private var openedBook: Book?
    @State private var route: BookActionRoute?
    @State private var saveError: String?
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
            .textualPageHeader { DiscoverTabBar(selection: $selection) }
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
                DiscoverForYouObserver(userID: repository.userID, discovery: discovery)
            }
        }
        .task {
            rebuildFeeds()
            await discovery?.refreshAll()
        }
        .onChange(of: discovery?.revision) { _, _ in rebuildFeeds() }
        .onChange(of: books.map(\.id), initial: true) { _, _ in archive = DiscoveryArchiveIndex(books: books) }
        .onChange(of: selection) { previous, current in
            if let previous { feeds[previous]?.adoptPending() }
            // An empty tab checks again when opened (still subject to failure backoff).
            if let current, feeds[current]?.items.isEmpty == true { Task { await refreshQuietly(current) } }
        }
        .onChange(of: isActive) { _, active in
            if !active { feeds.values.forEach { $0.adoptPending() } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { feeds.values.forEach { $0.adoptPending() } }
            if phase == .active, isActive { Task { await discovery?.refreshAll() } }
        }
    }

    @ViewBuilder
    private func page(_ tab: DiscoverTab) -> some View {
        if tab == .friends {
            DiscoverFriendsPage()
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

    private func rebuildFeeds() {
        guard let discovery else { return }
        feeds[.trending]?.offer(discovery.items(.trending))
        let newReleases = discovery.items(.newReleases).map { $0.withFacet("new-releases") }
        feeds[.explore]?.offer(DiscoveryExploreOrder.order(discovery.items(.explore) + newReleases, seed: exploreSeed))
        feeds[.forYou]?.offer(discovery.items(.forYou))
    }

    private func refresh(_ tab: DiscoverTab) async {
        await discovery?.refreshAll(force: true)
        rebuildFeeds()
        feeds[tab]?.adoptPending()
    }

    private func refreshQuietly(_ tab: DiscoverTab) async {
        switch tab {
        case .trending: await discovery?.refresh(.trending)
        case .explore, .forYou: await discovery?.refreshAll()
        case .friends: return
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

// MARK: - Tabs

private struct DiscoverTabBar: View {
    @Binding var selection: DiscoverTab?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ViewThatFits(in: .horizontal) {
            tabs.frame(maxWidth: .infinity)
            ScrollView(.horizontal) { tabs.padding(.horizontal, TextualLayout.pageInset) }
                .scrollIndicators(.hidden)
        }
        .frame(minHeight: TextualLayout.touchTarget)
    }

    private var tabs: some View {
        HStack(spacing: 28) {
            ForEach(DiscoverTab.allCases) { tab in
                Button {
                    withAnimation(reduceMotion ? nil : .snappy) { selection = tab }
                } label: {
                    Text(tab.title)
                        .font(.designSystem(.uiButton))
                        .foregroundStyle(selection == tab ? Color.paper : Color.ghost)
                        .fixedSize()
                        .frame(minHeight: TextualLayout.touchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
                .accessibilityIdentifier("discover.tab.\(tab.rawValue)")
            }
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
    @ViewBuilder let cell: (DiscoverItem, CGSize) -> Cell

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 0).id("top")
                    if feed.items.isEmpty {
                        if failed && !isLoading { unavailable } else { DiscoverPlaceholderGrid() }
                    } else {
                        MasonryGrid(items: feed.visibleItems, aspect: \.aspect, onNearEnd: feed.loadMore, cell: cell)
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

/// Friends needs the follow system; until it exists this stays honest and empty.
private struct DiscoverFriendsPage: View {
    var body: some View {
        ScrollView {
            TextualEmptyState(title: "Nothing here yet", icon: .people,
                detail: "When you follow other readers, the books they’re reading and loving will gather here.")
                .foregroundStyle(Color.paper)
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
    @Query(filter: #Predicate<Book> { !$0.isRemovedFromLibrary }) private var books: [Book]
    @Query private var profiles: [ReaderProfileDraft]
    @Query private var reviews: [ReaderReviewDraft]

    private struct Trigger: Equatable {
        let books: [UUID]
        let reading: [Data?]
        let favorites: Data?
        let reviews: [Data?]
        let pools: Int
    }

    var body: some View {
        let profile = profiles.first { $0.userID == userID }
        let trigger = Trigger(books: books.map(\.id), reading: books.map(\.storyGraphData),
                              favorites: profile?.contentData,
                              reviews: reviews.filter { $0.userID == userID }.map { $0.pendingData ?? $0.remoteData },
                              pools: discovery.revision)
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            .task(id: trigger) {
                // Debounce bursts (imports, sync) and give the visible screen priority.
                do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
                await rank()
            }
    }

    private func tasteBooks() -> [DiscoveryTasteBook] {
        let favorites = profiles.first { $0.userID == userID }?.content?.favorites ?? []
        let drafts = Dictionary(reviews.filter { $0.userID == userID }.map { ($0.localBookID, $0) },
                                uniquingKeysWith: { first, _ in first })
        var matched = Set<UUID>()
        var result = books.map { book -> DiscoveryTasteBook in
            let rank = favorites.firstIndex { $0.matches(book) }
            if let rank { matched.insert(favorites[rank].id) }
            let quarterStars = ReaderReviewPresentation(book: book, draft: drafts[book.id]).content?.rating
            return DiscoveryTasteBook(catalogID: book.googleBooksVolumeId, title: book.title, author: book.author,
                isbns: [book.isbn], genres: StatsMetadataCache.genres(book), status: book.importedReading?.status,
                rating: quarterStars.map { Double($0) / 4 }, favoriteRank: rank)
        }
        // Shelf favorites that are no longer in the archive still describe taste.
        for (rank, favorite) in favorites.enumerated() where !matched.contains(favorite.id) {
            result.append(DiscoveryTasteBook(catalogID: favorite.catalogID, title: favorite.title,
                author: favorite.author, isbns: [favorite.isbn], favoriteRank: rank))
        }
        return result
    }

    private func rank() async {
        let taste = tasteBooks()
        let now = Date()
        let seed = DiscoverySeed.daily(userID: userID, date: now)
        await refreshAuthorCandidates(taste)
        let pools: [DiscoveryCollection] = [.trending, .newReleases, .explore, .forYouAuthors]
        let poolStamp = pools.map { "\($0.rawValue):\(discovery.state($0)?.fetchedAt?.timeIntervalSince1970 ?? 0)" }
        let tasteStamp = taste.map {
            "\($0.catalogID ?? "")|\($0.title)|\($0.author)|\($0.status ?? "")|\($0.rating ?? -1)|\($0.favoriteRank ?? -1)|\($0.genres.sorted().joined(separator: ","))"
        }.sorted()
        let signature = DiscoverySeed.signature(["v1", String(seed)] + poolStamp + tasteStamp)
        guard discovery.state(.forYou)?.inputSignature != signature || discovery.items(.forYou).isEmpty else { return }

        var collections: [String: Set<String>] = [:]
        var items: [String: DiscoverItem] = [:]
        for pool in pools {
            for item in discovery.items(pool) {
                items[item.catalogID] = items[item.catalogID] ?? item
                collections[item.catalogID, default: []].insert(pool == .forYouAuthors ? "author" : pool.rawValue)
            }
        }
        guard !items.isEmpty else { return }
        let candidates = items.values.map { DiscoveryCandidate(item: $0, collections: collections[$0.catalogID] ?? []) }
            .sorted { $0.item.catalogID < $1.item.catalogID }
        let ranked = await Task.detached(priority: .utility) {
            DiscoveryRecommender.recommend(books: taste, candidates: candidates, seed: seed)
        }.value
        guard !Task.isCancelled else { return }
        try? discovery.store(ranked.map { ($0.item, $0.reasons) }, in: .forYou, signature: signature)
    }

    /// Other books by the reader's most-loved authors, looked up at most weekly and
    /// only when those authors change. Uses the shared, rate-limited catalog service.
    private func refreshAuthorCandidates(_ taste: [DiscoveryTasteBook]) async {
        let profile = DiscoveryRecommender.profile(taste)
        var names: [String: String] = [:]
        for book in taste { names[DiscoveryIdentity.primaryAuthorKey(book.author)] = names[DiscoveryIdentity.primaryAuthorKey(book.author)] ?? book.author.components(separatedBy: ",").first }
        let authors = profile.authors.filter { $0.value >= 4 && $0.key != "unknown author" }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(4)
            .compactMap { names[$0.key]?.trimmingCharacters(in: .whitespacesAndNewlines) }
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
