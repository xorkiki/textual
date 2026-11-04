import SwiftUI
import SwiftData
import Supabase
import PhotosUI

struct ReaderProfileView: View {
    let account: AccountSession
    var isPresentedAsSheet = false
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Book> { !$0.isRemovedFromLibrary }, sort: \Book.title) private var books: [Book]
    @Query private var drafts: [ReaderProfileDraft]
    @Environment(\.modelContext) private var context
    @Environment(\.readingLibrary) private var readingLibrary
    @Environment(\.socialStore) private var social
    @State private var publicationTask: Task<Void, Never>?
    @State private var openedStat: ReaderCardStat?
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: ReaderProfileStore?
    @State private var showPicker = false
    @State private var showReaders = false
    @State private var showPreview = false
    @State private var selectedBook: Book?
    @State private var saveError: String?
    @State private var incomingUsername: String?
    @State private var showPhotoPicker = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isPreparingPhoto = false
    @State private var photoError: String?

    private var draft: ReaderProfileDraft? { drafts.first { $0.userID == account.userID } }
    private var content: ReaderPublicContent {
        var result = readingLibrary?.profile ?? ReaderPersonality.summarize(ReaderPersonality.evidence(books), favorites: [])
        let byID = Dictionary(books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        result.favorites = (draft?.content?.favorites ?? []).map { favorite in
            favorite.refreshed(from: byID[favorite.id].map { [$0] } ?? books)
        }
        result.avatarPath = draft?.content?.avatarPath
        // Only a database with the social migration accepts the breakdown.
        if social?.settings.isLoaded != true { result.genreBreakdown = nil }
        return result
    }
    private var avatarTransport: (any ReaderAvatarTransport)? {
        account.client.map { SupabaseReaderProfileTransport(client: $0) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 30) {
                    ReaderLibraryCard(firstName: account.profile?.firstName ?? "reader",
                                      username: account.profile?.username ?? "reader", content: content,
                                      avatarData: draft?.matchingAvatarData, avatarTransport: avatarTransport,
                                      choosePhoto: { showPhotoPicker = true }, isPreparingPhoto: isPreparingPhoto,
                                      selectStat: { openedStat = $0 })
                    ProfileFriendsSection(username: account.profile?.username ?? "", isOwner: true)
                    ReaderBookshelf(readerName: account.profile?.firstName ?? "reader", favorites: content.favorites, isOwner: true,
                        add: { showPicker = true },
                        move: { id, target in saveFavorites(ReaderShelf.moving(id, to: target, in: content.favorites)) },
                        remove: { id in saveFavorites(content.favorites.filter { $0.id != id }) },
                        onCoverResolved: { favorite, url in
                            books.first(where: { favorite.matches($0) })?.rememberCover(url)
                        },
                        open: { favorite in
                            selectedBook = books.first(where: { favorite.matches($0) }) ?? favorite.detailBook()
                        })
                    if let message = store?.message {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(message).foregroundStyle(Color.ghost)
                            if store?.conflictingProfile != nil {
                                Button("Keep this profile") { resolve(keepLocal: true) }
                                Button("Use synced profile") { resolve(keepLocal: false) }
                            } else {
                                Button("Try again") { synchronize() }
                            }
                        }
                        .font(.designSystem(.uiLabel))
                        .foregroundStyle(Color.paper)
                    }
                }
                .padding(.horizontal, TextualLayout.pageInset).padding(.top, 12)
                .padding(.bottom, TextualNavigationLayout.bottomExtent + 24)
                .frame(maxWidth: 650).frame(maxWidth: .infinity)
            }
            .background(Color.inkwell.ignoresSafeArea())
            .scrollIndicators(.hidden)
            .textualPageHeader { header }
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await syncNow() }
            .navigationDestination(item: $selectedBook) { BookDetailView(book: $0) }
            .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images,
                          preferredItemEncoding: .compatible)
            .task(id: selectedPhoto) { await loadSelectedPhoto() }
            .sheet(isPresented: $showPicker) {
                ReaderFavoritePicker(books: books, favorites: content.favorites, save: saveFavorites)
            }
            .sheet(item: $openedStat) { stat in
                OwnerStatSheet(stat: stat, books: books,
                    genres: readingLibrary?.profile.genreBreakdown ?? content.genreBreakdown ?? [],
                    completedReads: Dictionary(uniqueKeysWithValues:
                        (readingLibrary?.snapshot.entries ?? []).map {
                            ($0.id, $0.reading.map(ReadingStatsFilter.completedCount) ?? 0)
                        }),
                    knownGenres: Dictionary(uniqueKeysWithValues:
                        (readingLibrary?.snapshot.entries ?? []).map { ($0.id, $0.genres) }))
            }
            .sheet(isPresented: $showPreview) {
                NavigationStack {
                    PublicReaderProfilePage(firstName: account.profile?.firstName ?? "reader",
                                            username: account.profile?.username ?? "reader", content: content,
                                            avatarData: draft?.matchingAvatarData, avatarTransport: avatarTransport,
                                            hiddenStats: hiddenFromVisitors, isOwner: true)
                        .textualSheetHeader("Public view") { showPreview = false }
                }
                .preferredColorScheme(.dark)
            }
            .sheet(isPresented: $showReaders) {
                ReaderProfileLookup(initialUsername: incomingUsername ?? "")
                    .environment(\.socialStore, social)
            }
            .alert("Couldn’t add photo", isPresented: Binding(get: { photoError != nil }, set: { if !$0 { photoError = nil } })) {
                Button("OK") { photoError = nil }
            } message: { Text(photoError ?? "") }
            .alert("Couldn’t save profile", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK") { saveError = nil }
            } message: { Text(saveError ?? "") }
            .task {
                guard let id = account.userID, let client = account.client else { return }
                if store == nil { store = ReaderProfileStore(userID: id, context: context, transport: SupabaseReaderProfileTransport(client: client)) }
                if readingLibrary == nil || readingLibrary?.isReady == true {
                    saveContent(content)
                    await syncNow()
                }
            }
            .onChange(of: content) { _, updated in
                schedulePublication()
            }
            .onChange(of: readingLibrary?.isReady) { _, ready in
                if ready == true { schedulePublication() }
            }
            .onDisappear { publicationTask?.cancel() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { synchronize() } }
            .onOpenURL { url in
                guard let username = ReaderProfileRoute.username(url) else { return }
                incomingUsername = username
                showReaders = true
            }
        }
    }

    /// What the owner's privacy settings keep off the public card (the preview shows it too).
    private var hiddenFromVisitors: Set<ReaderCardStat> {
        guard let settings = social?.settings.settings else { return [] }
        var hidden = Set<ReaderCardStat>()
        if !settings.booksReadVisible { hidden.insert(.reads) }
        if !settings.genresVisible { hidden.insert(.genres) }
        if !settings.rereadsVisible { hidden.insert(.rereads) }
        return hidden
    }

    private var header: some View {
        TextualHeader(title: "PROFILE") {
            HStack(spacing: TextualLayout.groupGap) {
                Button { showPreview = true } label: { DesignSystemIconView(.preview) }
                    .buttonStyle(IconButtonStyle())
                    .accessibilityLabel("Preview public profile")
                    .accessibilityIdentifier("profile.publicPreview")
                if isPresentedAsSheet { TextualCloseButton { dismiss() } }
            }
        }
    }

    private func saveContent(_ content: ReaderPublicContent, addedFavorites: [UUID] = []) {
        do { try store?.update(content, addedFavorites: addedFavorites, stamp: social?.settings.stamp) }
        catch { saveError = "Your shelf couldn’t be saved. Please try again."; context.rollback() }
    }

    private func loadSelectedPhoto() async {
        guard let selectedPhoto, let userID = account.userID, let store else { return }
        isPreparingPhoto = true
        defer { isPreparingPhoto = false; self.selectedPhoto = nil }
        do {
            guard let data = try await selectedPhoto.loadTransferable(type: Data.self) else {
                throw ReaderAvatar.PhotoError.invalid
            }
            let prepared = try await ReaderAvatarProcessor.shared.prepare(data)
            try Task.checkCancellation()
            guard account.userID == userID else { throw LibraryRepositoryError.accountChanged }
            try store.setAvatar(prepared)
            // Persist first; account sync can retry independently of the picker/view lifecycle.
            synchronize()
        } catch is CancellationError { }
        catch {
            context.rollback()
            photoError = (error as? ReaderAvatar.PhotoError)?.errorDescription ?? "Your photo couldn’t be saved. Please try again."
        }
    }

    private func saveFavorites(_ favorites: [ReaderFavorite]) {
        var updated = content
        updated.favorites = Array(favorites.prefix(ReaderShelf.limit))
        // Only books newly placed on the shelf can become activity; reorders never do.
        let previous = Set(content.favorites.map(\.id))
        saveContent(updated, addedFavorites: updated.favorites.map(\.id).filter { !previous.contains($0) })
        synchronize()
    }

    private func schedulePublication() {
        publicationTask?.cancel()
        guard readingLibrary == nil || readingLibrary?.isReady == true else { return }
        publicationTask = Task {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard !Task.isCancelled else { return }
            saveContent(content)
            await syncNow()
        }
    }

    private func synchronize() { Task { await syncNow() } }
    private func syncNow() async {
        guard let username = account.profile?.username else { return }
        await store?.synchronize(username: username)
    }
    private func resolve(keepLocal: Bool) {
        do { try store?.resolveConflict(keepLocal: keepLocal); synchronize() }
        catch { saveError = "Your shelf couldn’t be saved. Please try again." }
    }
}

/// The owner's card uses the same cover-only detail sheet as Stats, backed by
/// their local archive so these taps never wait for a profile RPC.
private struct OwnerStatSheet: View {
    let stat: ReaderCardStat
    let books: [Book]
    let genres: [ReaderGenreShare]
    let completedReads: [UUID: Int]
    let knownGenres: [UUID: Set<String>]
    @Environment(\.dismiss) private var dismiss
    @State private var selectedBook: Book?
    @State private var selectedGenre: GenreSelection?

    private struct GenreSelection: Identifiable {
        let name: String
        var id: String { name }
    }

    private var matches: [Book] {
        books.filter { book in
            let count = completedReads[book.id] ?? 0
            return stat == .reads ? count > 0 : count > 1
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.inkwell.ignoresSafeArea()
                ScrollView {
                    if stat == .genres {
                        GenreStatsChart(genres: genres.map { GenreStat(name: $0.name, count: $0.reads ?? $0.books) },
                                        showsHeading: false) {
                            selectedGenre = GenreSelection(name: $0)
                        }
                        .padding(TextualLayout.pageInset)
                    } else if matches.isEmpty {
                        TextualEmptyState(title: "No books yet", icon: .archive,
                                          detail: "Books in this category will appear here.")
                            .padding(TextualLayout.pageInset)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 16)], spacing: 20) {
                            ForEach(matches) { book in
                                Button { selectedBook = book } label: {
                                    SavedBookCover(book: book, width: 120, height: 180)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(book.title) by \(book.author)")
                            }
                        }
                        .padding(TextualLayout.pageInset)
                    }
                }
                .scrollIndicators(.hidden)
            }
            .textualSheetHeader(stat.title) { dismiss() }
            .sheet(item: $selectedBook) { book in
                NavigationStack { BookDetailView(book: book, isPresentedAsSheet: true) }
            }
            .sheet(item: $selectedGenre) { genre in
                OwnerGenreBooksSheet(name: genre.name, books: books,
                    completedReads: completedReads, knownGenres: knownGenres)
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct OwnerGenreBooksSheet: View {
    let name: String
    let books: [Book]
    let completedReads: [UUID: Int]
    let knownGenres: [UUID: Set<String>]
    @Environment(\.dismiss) private var dismiss
    @State private var selectedBook: Book?

    private var matches: [Book] {
        books.filter { book in
            guard (completedReads[book.id] ?? 0) > 0 else { return false }
            let genres = knownGenres[book.id] ?? []
            return name == "Unclassified" ? genres.isEmpty : genres.contains(name)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if matches.isEmpty {
                    TextualEmptyState(title: "No matching books", icon: .archive,
                                      detail: "There are no books in this genre yet.")
                        .padding(TextualLayout.pageInset)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 16)], spacing: 20) {
                        ForEach(matches) { book in
                            Button { selectedBook = book } label: {
                                SavedBookCover(book: book, width: 120, height: 180)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(book.title) by \(book.author)")
                        }
                    }
                    .padding(TextualLayout.pageInset)
                }
            }
            .background(Color.inkwell.ignoresSafeArea())
            .textualSheetHeader(name) { dismiss() }
            .sheet(item: $selectedBook) { book in
                NavigationStack { BookDetailView(book: book, isPresentedAsSheet: true) }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct ReaderFavoritePicker: View {
    let books: [Book]
    let favorites: [ReaderFavorite]
    let save: ([ReaderFavorite]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: [ReaderFavorite] = []
    @State private var query = ""

    private var matches: [Book] {
        books.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.author.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 85), spacing: 16)], spacing: 24) {
                    ForEach(matches) { book in
                        let selected = selection.contains { $0.matches(book) }
                        Button {
                            if selected { selection.removeAll { $0.matches(book) } }
                            else { selection = ReaderShelf.adding(book, to: selection) }
                        } label: {
                            SavedBookCover(book: book, width: 90, height: 135)
                                .overlay(alignment: .topTrailing) {
                                    DesignSystemIconView(selected ? .selected : .unselected, size: TextualIconStyle.selection.size)
                                        .foregroundStyle(Color.paper)
                                        .background(Color.inkwell, in: Circle()).padding(5)
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(!selected && selection.count >= ReaderShelf.limit)
                        .opacity(!selected && selection.count >= ReaderShelf.limit ? 0.4 : 1)
                        .accessibilityLabel("\(book.title), by \(book.author)")
                        .accessibilityValue(selected ? "Selected" : "Not selected")
                    }
                }
                .padding(TextualLayout.pageInset)
                if matches.isEmpty {
                    Text(books.isEmpty ? "your archive is still a blank page. add a book, then give it a place here." : "nothing on this shelf by that name.")
                        .font(.designSystem(.sectionHeading)).foregroundStyle(Color.ghost).padding(TextualLayout.pageInset)
                }
            }
            .background(Color.inkwell.ignoresSafeArea())
            .textualPageHeader {
                VStack(spacing: TextualLayout.itemGap) {
                    TextualHeader(title: "Add to your shelf") {
                        HStack(spacing: TextualLayout.groupGap) {
                            IconButton(icon: .checkmark) { save(selection); dismiss() }
                                .accessibilityLabel("Save shelf selection")
                            TextualCloseButton(label: "Cancel shelf selection") { dismiss() }
                        }
                    }
                    TextualSearchField("Search your archive", text: $query)
                        .padding(.horizontal, TextualLayout.pageInset)
                }
            }
            .onAppear { selection = favorites }
        }
        .preferredColorScheme(.dark).tint(.paper)
    }
}

/// The public profile layout: the owner's eye-icon preview and every visitor route.
struct PublicReaderProfilePage: View {
    let firstName: String
    let username: String
    let content: ReaderPublicContent
    var avatarData: Data? = nil
    var avatarTransport: (any ReaderAvatarTransport)? = nil
    var hiddenStats: Set<ReaderCardStat> = []
    var selectStat: ((ReaderCardStat) -> Void)? = nil
    var isOwner = false
    @State private var selectedBook: Book?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                ReaderLibraryCard(firstName: firstName, username: username, content: content,
                                  avatarData: avatarData, avatarTransport: avatarTransport,
                                  hiddenStats: hiddenStats, selectStat: selectStat)
                ProfileFriendsSection(username: username, isOwner: isOwner)
                ReaderBookshelf(readerName: firstName, favorites: content.favorites, open: { selectedBook = $0.detailBook() })
            }
            .padding(TextualLayout.pageInset).frame(maxWidth: 650).frame(maxWidth: .infinity)
        }
        .background(Color.inkwell.ignoresSafeArea())
        .navigationDestination(item: $selectedBook) { BookDetailView(book: $0) }
    }
}

/// A compact preview of accepted friendships. The full list is fetched only when
/// opened, so profiles don't fetch hundreds of readers just to show five photos.
struct ProfileFriendsSection: View {
    let username: String
    var isOwner = false
    @Environment(\.socialStore) private var social
    @State private var friends: [SocialReader] = []
    @State private var loaded = false
    @State private var failure: String?
    @State private var showList = false

    var body: some View {
        VStack(alignment: .leading, spacing: TextualLayout.itemGap) {
            TextualHeading(title: "Friends")
            GeometryReader { geometry in
                let count = max(1, min(5, Int((geometry.size.width - 44 + 8) / 48)))
                HStack(spacing: 8) {
                    ForEach(Array(friends.prefix(count))) { reader in
                        ReaderAvatarBadge(reader: reader, size: 40, circle: true)
                            .frame(width: 40, height: 40)
                            .accessibilityLabel("\(reader.firstName), @\(reader.username)")
                    }
                    if friends.isEmpty {
                        Text(failure ?? (loaded ? "No friends yet" : "Loading friends…"))
                            .textStyle(.bodySmall).foregroundStyle(Color.ghost)
                    }
                    Spacer(minLength: 0)
                    Button { showList = true } label: {
                        DesignSystemIconView(.chevronRight, size: TextualIconStyle.compact.size)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("See all friends")
                    .accessibilityIdentifier("profile.allFriends")
                }
            }
            .frame(height: 44)
        }
        .task(id: username) { await load() }
        .sheet(isPresented: $showList, onDismiss: { Task { await load() } }) {
            ProfileFriendsList(username: username, isOwner: isOwner)
        }
    }

    private func load() async {
        guard let social, !username.isEmpty else { return }
        do {
            let page = try await social.profileFriends(username: username, after: nil, limit: 5)
            friends = page.friends
            loaded = true
            failure = nil
        } catch is CancellationError { }
        catch { failure = "Friends couldn’t load." }
    }
}

private struct ProfileFriendsList: View {
    let username: String
    let isOwner: Bool
    @Environment(\.socialStore) private var social
    @Environment(\.dismiss) private var dismiss
    @State private var friends: [SocialReader] = []
    @State private var next: String?
    @State private var loaded = false
    @State private var loading = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: TextualLayout.groupGap) {
                    ForEach(friends) { reader in
                        SocialReaderRow(reader: reader) {
                            if let social, !isOwner, reader.userID != social.userID {
                                if reader.relationship?.state == ReaderRelationship.State.none {
                                    Button { Task { await act(.send, reader) } } label: {
                                        DesignSystemIconView(.add, size: TextualIconStyle.compact.size)
                                    }
                                    .disabled(social.pending.contains(reader.userID))
                                    .accessibilityLabel("Add \(reader.firstName) as a friend")
                                    .accessibilityIdentifier("profile.addFriend.\(reader.username)")
                                } else if reader.relationship?.state == ReaderRelationship.State.incoming {
                                    Button { Task { await act(.accept, reader) } } label: {
                                        DesignSystemIconView(.checkmark, size: TextualIconStyle.compact.size)
                                    }
                                    .disabled(social.pending.contains(reader.userID))
                                    .accessibilityLabel("Accept \(reader.firstName)’s friend request")
                                }
                            }
                        }
                        .onAppear {
                            if reader.id == friends.last?.id { Task { await loadMore() } }
                        }
                    }
                    if loading { ProgressView().tint(.paper).frame(maxWidth: .infinity) }
                    if friends.isEmpty && loaded && failure == nil {
                        TextualEmptyState(title: "No friends yet", icon: .people,
                                          detail: "Friends will appear here once requests are accepted.")
                    }
                    if let failure {
                        Text(failure).textStyle(.bodySmall).foregroundStyle(Color.ghost)
                        Button("Try again") { Task { await loadMore() } }
                    }
                }
                .padding(TextualLayout.pageInset)
            }
            .background(Color.inkwell.ignoresSafeArea())
            .textualSheetHeader("Friends") { dismiss() }
            .navigationDestination(for: ReaderRoute.self) { PublicReaderProfileView(username: $0.username) }
            .refreshable { await reload() }
            .task { await loadMore() }
        }
        .preferredColorScheme(.dark)
    }

    private func reload() async {
        friends = []; next = nil; loaded = false; failure = nil
        await loadMore()
    }

    private func loadMore() async {
        guard let social, !loading, !loaded || next != nil else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await social.profileFriends(username: username, after: next)
            friends += page.friends.filter { reader in !friends.contains { $0.id == reader.id } }
            next = page.next
            loaded = true
            failure = nil
        } catch is CancellationError { }
        catch { failure = "Friends couldn’t load. Please try again." }
    }

    private func act(_ action: FriendshipAction, _ reader: SocialReader) async {
        guard let social, await social.perform(action, with: reader) else { return }
        await reload()
    }
}

/// Reader links (textual://reader/<username>) open the same visitor route as Community.
private struct ReaderProfileLookup: View {
    let initialUsername: String
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var route: ReaderRoute?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("a familiar face in the stacks")
                    .font(.designSystem(.heading3))
                TextField("username", text: $username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(16).background(Color.velvet, in: Capsule())
                    .submitLabel(.search).onSubmit { lookup() }
                Button("Find reader") { lookup() }.disabled(username.isEmpty)
                if let message { Text(message).font(.designSystem(.caption)).foregroundStyle(Color.ghost) }
            }
            .padding(TextualLayout.pageInset).frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(Color.paper).background(Color.inkwell.ignoresSafeArea())
            .textualPageHeader {
                TextualHeader(title: "Find a reader") { TextualCloseButton { dismiss() } }
            }
            .navigationDestination(item: $route) { PublicReaderProfileView(username: $0.username) }
            .onAppear { username = initialUsername; if !username.isEmpty { lookup() } }
        }
        .preferredColorScheme(.dark).tint(.paper)
    }

    private func lookup() {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "@", with: "").lowercased()
        guard ReaderProfileRoute.isValidUsername(name) else { message = "Try a username with 3–30 letters, numbers, or underscores."; return }
        message = nil
        route = ReaderRoute(username: name)
    }
}

enum ReaderProfileRoute {
    static func isValidUsername(_ value: String) -> Bool {
        value.range(of: "^[a-z0-9_]{3,30}$", options: .regularExpression) != nil
    }
    static func username(_ url: URL) -> String? {
        guard url.scheme == "textual", url.host == "reader", url.pathComponents.count == 2,
              let name = url.pathComponents.last, isValidUsername(name) else { return nil }
        return name
    }
}
