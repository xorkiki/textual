import SwiftUI
import SwiftData

/// Navigation value for visiting a reader's public profile.
struct ReaderRoute: Hashable, Identifiable {
    let username: String
    var id: String { username }
}

/// The existing public profile page for a selected reader, read through the
/// permission-filtered endpoint. Visitors see only what the owner shows; nothing
/// here can edit the owner's card or shelf.
struct PublicReaderProfileView: View {
    let username: String
    @Environment(\.socialStore) private var social
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var profile: VisitorProfile?
    @State private var failure: String?
    @State private var missing = false
    @State private var openedStat: ReaderCardStat?
    @State private var confirmation: FriendshipAction?

    var body: some View {
        Group {
            if let profile {
                PublicReaderProfilePage(firstName: profile.firstName, username: profile.username,
                                        content: profile.cardContent, avatarTransport: social?.avatarTransport,
                                        hiddenStats: profile.hiddenStats, selectStat: { openedStat = $0 },
                                        isOwner: profile.isOwner)
                    .refreshable { await load(force: true) }
            } else if missing {
                message("no card filed under that name. yet.")
            } else if let failure {
                VStack(spacing: TextualLayout.groupGap) {
                    message(failure)
                    Button("Try again") { Task { await load(force: true) } }
                        .buttonStyle(TextualButtonStyle(variant: .tonal))
                        .frame(maxWidth: 200)
                }
            } else {
                ProgressView().tint(.paper).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(Color.paper)
        .background(Color.inkwell.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .textualPageHeader {
            TextualHeader(title: "@\(username)", backAction: { dismiss() }) { relationshipAction }
        }
        .sheet(item: $openedStat) { stat in
            if let profile { ReaderStatSheet(profile: profile, stat: stat) }
        }
        .confirmationDialog(confirmationTitle, isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            if let confirmation {
                Button(confirmation == .remove ? "Remove friend" : "Cancel request", role: .destructive) {
                    Task { await act(confirmation) }
                }
            }
        }
        .task { await load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await load(force: true) } }
        }
        .accessibilityIdentifier("community.profile")
    }

    private func message(_ text: String) -> some View {
        Text(text).textStyle(.sectionHeading).foregroundStyle(Color.ghost)
            .multilineTextAlignment(.center).padding(TextualLayout.pageInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var relationshipAction: some View {
        if let profile, !profile.isOwner, let social {
            let state = profile.relationship?.state ?? .none
            let busy = social.pending.contains(profile.userID)
            if state == .incoming {
                Button { Task { await act(.accept) } } label: {
                    DesignSystemIconView(.checkmark, size: TextualIconStyle.compact.size)
                }
                .buttonStyle(IconButtonStyle())
                .disabled(busy)
                .accessibilityLabel(busy ? "Sending friend request" : "Accept friend request")
                .accessibilityIdentifier("profile.relationship")
            } else {
                Button(busy ? "Sending…" : Self.title(state)) {
                    switch state {
                    case .none: Task { await act(.send) }
                    case .incoming: break
                    case .outgoing: confirmation = .cancel
                    case .friends: confirmation = .remove
                    }
                }
                .disabled(busy)
                .accessibilityIdentifier("profile.relationship")
            }
        }
    }

    static func title(_ state: ReaderRelationship.State) -> String {
        switch state {
        case .none: return "Add friend"
        case .outgoing: return "Requested"
        case .incoming: return "Accept"
        case .friends: return "Friends"
        }
    }

    private var confirmationTitle: String {
        guard let profile else { return "" }
        return confirmation == .remove ? "Remove \(profile.firstName) as a friend?" : "Cancel your friend request?"
    }

    private func act(_ action: FriendshipAction) async {
        guard let social, let profile else { return }
        await social.perform(action, with: profile.reader)
        await load(force: true)
    }

    private func load(force: Bool = false) async {
        guard let social else { failure = SocialError.unavailable.errorDescription; return }
        do {
            let loaded = try await social.loadProfile(username, force: force)
            guard !Task.isCancelled else { return }
            profile = loaded
            missing = loaded == nil
            failure = nil
        } catch is CancellationError {
        } catch {
            // An expired cached card is not shown when it can't be revalidated.
            if social.cachedProfile(username) == nil { profile = nil }
            failure = (error as? SocialError)?.errorDescription ?? SocialError.unavailable.errorDescription
        }
    }
}

extension VisitorProfile {
    /// The existing card model. Hidden counts never arrive; they display as a dash.
    var cardContent: ReaderPublicContent {
        ReaderPublicContent(stats: ReaderCardStats(reads: card?.booksRead.count ?? 0, genres: card?.genres.count ?? 0,
                                                   rereads: card?.rereads.count ?? 0),
                            sentence: sentence ?? "", favorites: favorites, avatarPath: avatarPath)
    }

    var hiddenStats: Set<ReaderCardStat> {
        var hidden = Set<ReaderCardStat>()
        if card?.booksRead.visible != true { hidden.insert(.reads) }
        if card?.genres.visible != true { hidden.insert(.genres) }
        if card?.rereads.visible != true { hidden.insert(.rereads) }
        return hidden
    }
}

/// Popups for a visitor's library-card statistics, using the Stats layouts.
struct ReaderStatSheet: View {
    let profile: VisitorProfile
    let stat: ReaderCardStat

    var body: some View {
        switch stat {
        case .reads: ProfileBooksSheet(username: profile.username, list: .read, title: stat.title)
        case .rereads: ProfileBooksSheet(username: profile.username, list: .rereads, title: stat.title)
        case .genres: ProfileGenresSheet(username: profile.username, shares: profile.card?.genres.breakdown ?? [])
        }
    }
}

/// The Stats category popup's cover grid, filled page by page from the server.
/// Covers open existing book details; nothing is added to the viewer's archive.
struct ProfileBooksSheet: View {
    let username: String
    let list: ProfileBookList
    let title: String
    var genre: String? = nil
    @Query(filter: #Predicate<Book> { !$0.isRemovedFromLibrary }) private var ownBooks: [Book]
    @Environment(\.reviewLibraryRepository) private var repository
    @Environment(\.socialStore) private var social
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var books: [ProfileBook] = []
    @State private var next: ProfileBooksPage.Cursor?
    @State private var loaded = false
    @State private var loading = false
    @State private var failure: String?
    @State private var selectedBook: Book?
    @State private var actionRoute: BookActionRoute?
    @State private var saveError: String?
    @State private var ownByCatalog: [String: Book] = [:]
    @State private var ownByISBN: [String: Book] = [:]

    var body: some View {
        NavigationStack {
            sheetContent
            .textualSheetHeader(title) { dismiss() }
            .sheet(item: $selectedBook) { book in
                NavigationStack { BookDetailView(book: book, isPresentedAsSheet: true) }
            }
            .sheet(item: $actionRoute) { route in BookActionSheet(route: route, repository: repository) }
            .alert("Couldn’t add book", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK") { saveError = nil }
            } message: { Text(saveError ?? "") }
            .task { await loadMore() }
            .onChange(of: ownBooks.map(\.id), initial: true) { _, _ in rebuildArchiveIndex() }
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("profile.books.\(genre ?? list.rawValue)")
    }

    private var sheetContent: some View {
        ZStack {
            Color.inkwell.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if loaded && books.isEmpty && failure == nil {
                        TextualEmptyState(title: "No books yet", icon: .archive,
                            detail: list == .rereads ? "Books read more than once will appear here." : "Finished books will appear here.")
                            .foregroundStyle(Color.paper)
                    } else {
                        bookGrid
                    }
                    if loading { ProgressView().tint(.paper).frame(maxWidth: .infinity) }
                    if let failure {
                        Text(failure).textStyle(.bodySmall).foregroundStyle(Color.ghost)
                        Button("Try again") { Task { await loadMore() } }
                            .buttonStyle(TextualButtonStyle(variant: .tonal))
                    }
                }
                .padding(TextualLayout.pageInset)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var bookGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 16, alignment: .top)], spacing: 20) {
            ForEach(books) { book in
                cover(book)
                    .onAppear { if book.id == books.last?.id { Task { await loadMore() } } }
            }
        }
    }

    private func cover(_ book: ProfileBook) -> some View {
        let archived = archiveBook(for: book)
        let actions = archived == nil ? BookAddStatus.allCases.map(\.menuAction) : BookQuickAction.allCases.map(\.menuAction)
        return HoldSlideSource(actions: actions, isEnabled: scenePhase == .active,
            open: { selectedBook = archived ?? book.detailBook() },
            select: { action in select(action, for: book) }) {
            BookCoverImage(urlString: book.coverURL ?? "", width: 120, height: 180,
                identity: BookCoverIdentity(title: book.title, author: book.author, isbn: book.isbn ?? "",
                    catalogID: book.catalogID.hasPrefix("storygraph:") ? nil : book.catalogID))
        }
        .frame(width: 120, height: 180)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(book.title) by \(book.author)")
        .accessibilityHint("Open book details. Touch and hold for archive actions.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { selectedBook = archived ?? book.detailBook() }
        .modifier(ProfileCoverActions(archived: archived,
            add: { add(book, status: $0) },
            quick: { actionRoute = BookActionRoute(book: $0, action: $1) }))
    }

    private func rebuildArchiveIndex() {
        ownByCatalog = Dictionary(ownBooks.compactMap { book in
            book.googleBooksVolumeId.map { ($0, book) }
        }, uniquingKeysWith: { first, _ in first })
        ownByISBN = Dictionary(ownBooks.filter { !$0.isbn.isEmpty }.map { ($0.isbn, $0) },
            uniquingKeysWith: { first, _ in first })
    }

    private func archiveBook(for book: ProfileBook) -> Book? {
        ownByCatalog[book.catalogID] ?? book.isbn.flatMap { ownByISBN[$0] }
    }

    private func select(_ action: String, for book: ProfileBook) {
        if let archived = archiveBook(for: book), let quick = BookQuickAction(rawValue: action) {
            actionRoute = BookActionRoute(book: archived, action: quick)
        } else if let status = BookAddStatus(rawValue: action) {
            add(book, status: status)
        }
    }

    private func add(_ book: ProfileBook, status: BookAddStatus) {
        guard archiveBook(for: book) == nil, let repository else { return }
        do {
            try repository.add(book.detailBook(), status: status)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            Task { await repository.synchronize() }
        } catch {
            saveError = "The book couldn’t be saved to your archive. Please try again."
        }
    }

    private func loadMore() async {
        guard let social, !loading, !loaded || next != nil else { return }
        loading = true
        defer { loading = false }
        do {
            let page: ProfileBooksPage
            if let genre {
                page = try await social.genreBooks(username: username, genre: genre, after: next)
            } else {
                page = try await social.books(username: username, list: list, after: next)
            }
            books += page.books.filter { book in !books.contains { $0.id == book.id } }
            next = page.next
            loaded = true
            failure = nil
        } catch SocialError.forbidden {
            // The owner hid this list: stop showing anything already loaded.
            books = []; next = nil; loaded = true
            failure = "This list is private."
        } catch is CancellationError {
        } catch {
            failure = (error as? SocialError)?.errorDescription ?? SocialError.unavailable.errorDescription
        }
    }
}

private struct ProfileCoverActions: ViewModifier {
    let archived: Book?
    let add: (BookAddStatus) -> Void
    let quick: (Book, BookQuickAction) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if let archived {
            content
                .accessibilityAction(named: "Save quote") { quick(archived, .quote) }
                .accessibilityAction(named: "Update progress") { quick(archived, .progress) }
                .accessibilityAction(named: "Finish and rate") { quick(archived, .finish) }
                .accessibilityAction(named: "Add note") { quick(archived, .note) }
        } else {
            content
                .accessibilityAction(named: "Add as read") { add(.read) }
                .accessibilityAction(named: "Add as currently reading") { add(.currentlyReading) }
                .accessibilityAction(named: "Add as to be read") { add(.tbr) }
                .accessibilityAction(named: "Add as did not finish") { add(.dnf) }
        }
    }
}

/// The Stats genre chart, read-only for visitors.
struct ProfileGenresSheet: View {
    let username: String
    let shares: [ReaderGenreShare]
    @Environment(\.dismiss) private var dismiss
    @State private var selectedGenre: GenreSelection?

    private struct GenreSelection: Identifiable {
        let name: String
        var id: String { name }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.inkwell.ignoresSafeArea()
                ScrollView {
                    GenreStatsChart(genres: shares.map { GenreStat(name: $0.name, count: $0.reads ?? $0.books) },
                                    showsHeading: false) {
                        selectedGenre = GenreSelection(name: $0)
                    }
                        .padding(24)
                }
                .scrollIndicators(.hidden)
            }
            .textualSheetHeader(ReaderCardStat.genres.title) { dismiss() }
            .sheet(item: $selectedGenre) { genre in
                ProfileBooksSheet(username: username, list: .read, title: genre.name, genre: genre.name)
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("profile.genres")
    }
}
