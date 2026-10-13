import SwiftUI
import SwiftData
import Supabase
import Observation

/// Owns one account's local store and releases its sync work on account changes.
struct AccountLibraryHost: View {
    let userID: UUID
    let session: AccountSession
    let legacyContainer: ModelContainer
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: AccountLibraryStore?
    @State private var openError: String?

    var body: some View {
        Group {
            if let store {
                TextualTabView(repository: store.repository, account: session,
                               legacyBookCount: store.legacyBookCount,
                               importLegacy: { try await store.importLegacyLibrary() })
                    .modelContainer(store.container)
                    .environment(\.readerReviews, store.reviews)
                    .environment(\.reviewLibraryRepository, store.repository)
                    .environment(\.discoveryRepository, store.discovery)
            } else if let openError {
                ContentUnavailableView {
                    Label("Library unavailable", textualIcon: .warning)
                } description: {
                    Text(openError)
                } actions: {
                    Button("Try again") {
                        openStore()
                        store?.repository.start()
                        Task { await store?.repository.synchronize() }
                    }
                    Button("Sign out") { Task { await session.signOut() } }
                }
            } else {
                ProgressView("Opening your library…")
            }
        }
        .task {
            openStore()
            store?.repository.start()
            await store?.repository.synchronize()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store?.repository.synchronize() } }
        }
        .onDisappear {
            store?.repository.stop()
            store?.reviews.stop()
            store?.discovery.stop()
            store = nil
        }
    }

    private func openStore() {
        guard store == nil, session.userID == userID, let client = session.client else { return }
        do {
            store = try AccountLibraryStore(userID: userID, client: client, legacyContainer: legacyContainer)
            openError = nil
        } catch {
            openError = "Your saved library couldn’t be opened. Your books have not been removed."
        }
    }
}

@MainActor
@Observable
final class AccountLibraryStore {
    let container: ModelContainer
    let repository: LibraryRepository
    let reviews: ReaderReviewStore
    let discovery: DiscoveryRepository
    private(set) var legacyBookCount = 0
    @ObservationIgnored private let legacyContainer: ModelContainer
    @ObservationIgnored private let userID: UUID
    @ObservationIgnored private let importMarker: String
    @ObservationIgnored private let defaults: UserDefaults

    init(userID: UUID, client: SupabaseClient, legacyContainer: ModelContainer,
         baseDirectory: URL? = nil, defaults: UserDefaults = .standard, projectHost: String? = nil) throws {
        self.userID = userID
        self.legacyContainer = legacyContainer
        self.defaults = defaults
        let project = projectHost ?? Secrets.supabaseConfiguration?.url.host ?? "unconfigured"
        importMarker = "textual.legacy-library-imported.\(project)"
        let base = try baseDirectory ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("Accounts", isDirectory: true)
            .appendingPathComponent(project, isDirectory: true)
            .appendingPathComponent(userID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let schema = Schema([Book.self, Tag.self, LibrarySyncState.self, ReaderProfileDraft.self, ReaderReviewDraft.self,
                             DiscoveryCacheEntry.self, DiscoveryCollectionState.self])
        let configuration = ModelConfiguration(schema: schema,
            url: directory.appendingPathComponent("library.store"), cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [configuration])
        repository = LibraryRepository(client: client, userID: userID, modelContext: container.mainContext)
        reviews = ReaderReviewStore(userID: userID, context: container.mainContext,
            transport: SupabaseReaderReviewTransport(client: client), repository: repository)
        discovery = DiscoveryRepository(context: container.mainContext,
                                        transport: SupabaseDiscoveryTransport(client: client))
        repository.afterSynchronization = { [weak reviews] in
            try? await reviews?.flush()
        }
        if defaults.string(forKey: importMarker) == nil {
            legacyBookCount = try legacyContainer.mainContext.fetchCount(FetchDescriptor<Book>(
                predicate: #Predicate<Book> { !$0.isRemovedFromLibrary }))
        }
    }

    /// Called only by an explicit import action. The original device library is preserved.
    func importLegacyLibrary() async throws {
        guard defaults.string(forKey: importMarker) == nil else {
            legacyBookCount = 0
            return
        }
        let existing = try legacyContainer.mainContext.fetch(FetchDescriptor<Book>(
            predicate: #Predicate<Book> { !$0.isRemovedFromLibrary }))
        for book in existing {
            var catalogID = book.volumeIdForDetailFetch
            if catalogID == nil, let cachedData = book.cachedCatalogMetadata,
               let cached = try? JSONDecoder().decode(BookCatalogService.BookItem.self, from: cachedData),
               let cachedID = cached.id?.trimmingCharacters(in: .whitespacesAndNewlines), !cachedID.isEmpty {
                catalogID = cachedID
            }
            if catalogID == nil {
                catalogID = try await BookCatalogService.shared.searchBookId(isbn: book.isbn)
            }
            guard let catalogID, !catalogID.isEmpty else { throw LibraryRepositoryError.missingCatalogID }
            let copy = Book(title: book.title, author: book.author, isbn: book.isbn,
                            coverURL: book.coverURL, googleBooksVolumeId: catalogID)
            copy.cachedCatalogMetadata = book.cachedCatalogMetadata
            copy.catalogMetadataUpdatedAt = book.catalogMetadataUpdatedAt
            try repository.add(copy)
        }
        defaults.set(userID.uuidString, forKey: importMarker)
        legacyBookCount = 0
    }
}

struct LibraryConflictsView: View {
    let repository: LibraryRepository
    @Query(filter: #Predicate<Book> { $0.syncConflictData != nil }, sort: \Book.title)
    private var conflicts: [Book]
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    Text("Choose which change to keep. Your local version stays saved until you choose.")
                        .foregroundStyle(Color.ghost)
                    ForEach(conflicts) { book in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(book.title).font(.designSystem(.uiButton))
                            Text(book.isRemovedFromLibrary ? "This iPhone removed the book." : "This iPhone saved or changed the book.")
                            Button("Keep this iPhone’s change") { resolve(book, keepLocal: true) }
                            Button("Use synced version") { resolve(book, keepLocal: false) }
                        }
                    }
                    if conflicts.isEmpty { Text("All changes are resolved.") }
                    if let errorMessage { Text(errorMessage).foregroundStyle(Color.errorText) }
                }
                .padding()
            }
            .textualSheetHeader("Review changes") { dismiss() }
        }
        .preferredColorScheme(.dark)
    }

    private func resolve(_ book: Book, keepLocal: Bool) {
        do {
            if keepLocal { try repository.resolveConflictKeepingLocal(book) }
            else { try repository.resolveConflictUsingServer(book) }
            errorMessage = nil
            Task { await repository.synchronize() }
        } catch {
            errorMessage = "The choice couldn’t be saved. Please try again."
        }
    }
}
