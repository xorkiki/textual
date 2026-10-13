import SwiftUI
import SwiftData
import Supabase
import PhotosUI

struct ReaderProfileView: View {
    let account: AccountSession
    @Query(filter: #Predicate<Book> { !$0.isRemovedFromLibrary }, sort: \Book.title) private var books: [Book]
    @Query private var drafts: [ReaderProfileDraft]
    @Environment(\.modelContext) private var context
    @Environment(\.readingLibrary) private var readingLibrary
    @State private var publicationTask: Task<Void, Never>?
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
                                      choosePhoto: { showPhotoPicker = true }, isPreparingPhoto: isPreparingPhoto)
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
            .sheet(isPresented: $showPreview) {
                NavigationStack {
                    PublicReaderProfilePage(firstName: account.profile?.firstName ?? "reader",
                                            username: account.profile?.username ?? "reader", content: content,
                                            avatarData: draft?.matchingAvatarData, avatarTransport: avatarTransport)
                        .textualSheetHeader("Public view") { showPreview = false }
                }
                .preferredColorScheme(.dark)
            }
            .sheet(isPresented: $showReaders) {
                if let client = account.client {
                    ReaderProfileLookup(transport: SupabaseReaderProfileTransport(client: client), initialUsername: incomingUsername ?? "")
                }
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

    private var header: some View {
        TextualHeader(title: "PROFILE") {
            Button { showPreview = true } label: { DesignSystemIconView(.preview) }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel("Preview public profile")
                .accessibilityIdentifier("profile.publicPreview")
        }
    }

    private func saveContent(_ content: ReaderPublicContent) {
        do { try store?.update(content) }
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
        saveContent(updated)
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

struct PublicReaderProfilePage: View {
    let firstName: String
    let username: String
    let content: ReaderPublicContent
    var avatarData: Data? = nil
    var avatarTransport: (any ReaderAvatarTransport)? = nil
    @State private var selectedBook: Book?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                ReaderLibraryCard(firstName: firstName, username: username, content: content,
                                  avatarData: avatarData, avatarTransport: avatarTransport)
                ReaderBookshelf(readerName: firstName, favorites: content.favorites, open: { selectedBook = $0.detailBook() })
            }
            .padding(TextualLayout.pageInset).frame(maxWidth: 650).frame(maxWidth: .infinity)
        }
        .background(Color.inkwell.ignoresSafeArea())
        .navigationDestination(item: $selectedBook) { BookDetailView(book: $0) }
    }
}

private struct ReaderProfileLookup: View {
    let transport: any ReaderProfileTransport
    let initialUsername: String
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var profile: PublicReaderProfile?
    @State private var message: String?
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            Group {
                if let profile {
                    PublicReaderProfilePage(firstName: profile.firstName, username: profile.username, content: profile.content,
                                            avatarTransport: transport)
                } else {
                    VStack(spacing: 16) {
                        Text("a familiar face in the stacks")
                            .font(.designSystem(.heading3))
                        TextField("username", text: $username)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(16).background(Color.velvet, in: Capsule())
                            .submitLabel(.search).onSubmit { lookup() }
                        Button("Find reader") { lookup() }.disabled(isLoading || username.isEmpty)
                        if isLoading { ProgressView() }
                        if let message { Text(message).font(.designSystem(.caption)).foregroundStyle(Color.ghost) }
                    }.padding(TextualLayout.pageInset).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .foregroundStyle(Color.paper).background(Color.inkwell.ignoresSafeArea())
            .textualPageHeader {
                TextualHeader(title: profile.map { "@\($0.username)" } ?? "Find a reader") {
                    HStack(spacing: TextualLayout.groupGap) {
                        if profile != nil {
                            IconButton(icon: .search) { profile = nil }
                                .accessibilityLabel("Find another reader")
                        }
                        TextualCloseButton { dismiss() }
                    }
                }
            }
            .onAppear { username = initialUsername; if !username.isEmpty { lookup() } }
        }
        .preferredColorScheme(.dark).tint(.paper)
    }

    private func lookup() {
        guard !isLoading else { return }
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "@", with: "").lowercased()
        guard ReaderProfileRoute.isValidUsername(name) else { message = "Try a username with 3–30 letters, numbers, or underscores."; return }
        isLoading = true; message = nil
        Task {
            defer { isLoading = false }
            do {
                profile = try await transport.fetch(username: name)
                if profile == nil { message = "no card filed under that name. yet." }
            } catch { message = "The library doors are sticking. Try again in a moment." }
        }
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
