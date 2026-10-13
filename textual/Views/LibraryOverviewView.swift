import SwiftUI
import SwiftData

struct LibraryView: View {
    var repository: LibraryRepository? = nil
    var bottomNavigationInset: CGFloat = 0
    @Query(filter: #Predicate<Book> { !$0.isRemovedFromLibrary }, sort: \Book.title) private var books: [Book]
    private enum Destination: Hashable { case upNext, allBooks, reviews, quotes }
    @State private var path: [Destination] = []
    @State private var selectedBook: Book?
    @State private var readingBook: Book?
    @State private var quickAction: BookActionRoute?
    @State private var showAddBook = false
    @State private var showQueuePicker = false
    @State private var saveError: String?
    @State private var showConflicts = false
    @Environment(\.modelContext) private var context

    @Environment(\.readingLibrary) private var readingLibrary
    private var currentlyReading: [Book] {
        if let readingLibrary { return books.filter { readingLibrary.snapshot.currentlyReading.contains($0.id) } }
        return books.filter { $0.importedReading?.status == "currently-reading" }
    }
    private var queue: [Book] { UpNextQueue.books(in: books) }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    VStack(alignment: .leading, spacing: 16) {
                        TextualHeading(title: "Currently reading").padding(.horizontal, TextualLayout.pageInset)
                        if currentlyReading.isEmpty {
                            Text("Your current reads will have a place here.")
                                .textStyle(.bodySmall).foregroundStyle(Color.ghost)
                                .padding(.horizontal, TextualLayout.pageInset)
                        } else {
                            ArchiveShelf(books: currentlyReading,
                                quickAction: { book, action in quickAction = .init(book: book, action: action) },
                                open: { readingBook = $0 })
                        }
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        NavigationLink(value: Destination.upNext) {
                            sectionHeading("Up next", count: queue.count)
                        }
                        ArchiveShelf(books: queue, add: { showQueuePicker = true },
                            move: { id, target in save(UpNextQueue.moving(id, to: target, in: queue)) },
                            remove: { book in save(queue.filter { $0.id != book.id }, removing: book) },
                            open: { selectedBook = $0 })
                    }

                    NavigationLink(value: Destination.allBooks) {
                        VStack(alignment: .leading, spacing: 16) {
                            sectionHeading("All books", count: books.count)
                            HStack(alignment: .bottom, spacing: 12) {
                                ForEach(Array(books.prefix(3))) { book in
                                    SavedBookCover(book: book, width: 86, height: 129)
                                        .accessibilityHidden(true)
                                }
                                if books.isEmpty {
                                    Text("Your archive starts with your first book.")
                                        .textStyle(.bodySmall).foregroundStyle(Color.ghost)
                                }
                                Spacer(minLength: 0)
                            }.padding(.horizontal, TextualLayout.pageInset)
                        }.contentShape(Rectangle())
                    }.accessibilityLabel("All books, \(books.count) books. Browse your archive")

                    VStack(alignment: .leading, spacing: 0) {
                        archiveLink("My reviews", to: .reviews)
                            .accessibilityIdentifier("archive.myReviews")
                        archiveLink("My quotes", to: .quotes)
                            .accessibilityIdentifier("archive.myQuotes")
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, bottomNavigationInset + 24)
            }
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .reviews:
                    ReaderReviewsView()
                case .quotes:
                    ReaderQuotesView()
                case .upNext:
                    UpNextView(repository: repository, bottomNavigationInset: bottomNavigationInset,
                        onBack: { path.removeAll() })
                case .allBooks:
                    ArchiveBooksView(repository: repository, bottomNavigationInset: bottomNavigationInset,
                        onBack: { path.removeAll() })
                }
            }
            .scrollIndicators(.hidden)
            .textualPageHeader {
                TextualHeader(title: "MY ARCHIVE", titleIdentifier: "archive.header") {
                    Button { showAddBook = true } label: { DesignSystemIconView(.add) }
                        .buttonStyle(IconButtonStyle())
                        .accessibilityLabel("Add a book")
                }
            }
            .background(Color.inkwell.ignoresSafeArea())
            .foregroundStyle(Color.paper)
            .buttonStyle(.plain)
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await repository?.synchronize() }
            .overlay(alignment: .bottom) {
                if let repository, let message = repository.message {
                    HStack(spacing: 12) {
                        Text(message).font(.designSystem(.uiLabel)).foregroundStyle(Color.paper)
                        Spacer()
                        if repository.syncState == .conflict {
                            Button("Review") { showConflicts = true }
                        } else if repository.syncState != .syncing {
                            Button("Retry") { Task { await repository.synchronize() } }
                        }
                    }
                    .padding().textualChromeBackground(edge: .bottom, fadeInside: true).tint(.paper)
                    .padding(.bottom, bottomNavigationInset + 8)
                }
            }
            .sheet(isPresented: $showConflicts) {
                if let repository { LibraryConflictsView(repository: repository) }
            }
            .sheet(isPresented: $showAddBook) { AddBookView(repository: repository) }
            .sheet(isPresented: $showQueuePicker) {
                NavigationStack {
                    ArchiveBooksView(choosingForQueue: true,
                        queuedIDs: Set(queue.map(\.id) + currentlyReading.map(\.id)), chooseBook: { book in
                            if save(queue + [book]) { showQueuePicker = false }
                        }, repository: repository, onBack: { showQueuePicker = false })
                }
            }
            .sheet(item: $readingBook) { book in
                NavigationStack { BookDetailView(book: book, isPresentedAsSheet: true, showsReadingActivity: true) }
            }
            .sheet(item: $quickAction) { BookActionSheet(route: $0, repository: repository) }
            .sheet(item: $selectedBook) { book in NavigationStack { BookDetailView(book: book, isPresentedAsSheet: true) } }
            .alert("Couldn’t save Up Next", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK") { saveError = nil }
            } message: { Text(saveError ?? "") }
        }
    }

    private func sectionHeading(_ title: String, count: Int) -> some View {
        HStack(spacing: 12) {
            TextualHeading(title: title)
            Spacer()
            Text("\(count)").textStyle(.bodySmall).foregroundStyle(Color.ghost)
            DesignSystemIconView(.arrowRight, size: 20, color: .ghost).accessibilityHidden(true)
        }.padding(.horizontal, TextualLayout.pageInset).contentShape(Rectangle())
    }

    private func archiveLink(_ title: String, to destination: Destination) -> some View {
        NavigationLink(value: destination) {
            HStack(spacing: 12) {
                TextualHeading(title: title)
                Spacer()
                DesignSystemIconView(.arrowRight, size: 20, color: .ghost)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, TextualLayout.pageInset)
            .frame(minHeight: TextualLayout.touchTarget)
            .contentShape(Rectangle())
        }
    }

    @discardableResult
    private func save(_ books: [Book], removing: Book? = nil) -> Bool {
        do {
            try UpNextQueue.save(books, removing: removing, context: context, repository: repository)
            Task { await repository?.synchronize() }
            return true
        } catch { saveError = "Your reading queue couldn’t be saved. Please try again."; return false }
    }
}

struct UpNextView: View {
    var repository: LibraryRepository?
    var bottomNavigationInset: CGFloat = 0
    var onBack: (() -> Void)? = nil
    @Query(filter: #Predicate<Book> { !$0.isRemovedFromLibrary }, sort: \Book.title) private var books: [Book]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false
    @State private var selectedBook: Book?
    @State private var saveError: String?
    private var queue: [Book] { UpNextQueue.books(in: books) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if queue.isEmpty {
                    Text("Choose your next read from your archive.")
                        .textStyle(.bodySmall).foregroundStyle(Color.ghost)
                        .padding(.horizontal, TextualLayout.pageInset)
                }
                ReaderBookshelf(readerName: "", kind: .upNext, favorites: queue.map(ReaderFavorite.init(book:)), isOwner: true,
                    add: { showPicker = true },
                    move: { id, target in save(UpNextQueue.moving(id, to: target, in: queue)) },
                    remove: { id in
                        if let book = queue.first(where: { $0.id == id }) {
                            save(queue.filter { $0.id != id }, removing: book)
                        }
                    },
                    onCoverResolved: { favorite, url in books.first { $0.id == favorite.id }?.rememberCover(url) },
                    open: { favorite in selectedBook = books.first { $0.id == favorite.id } })
                    .padding(.horizontal, TextualLayout.pageInset)
            }
            .padding(.top, 24).padding(.bottom, bottomNavigationInset + 24)
        }
        .scrollIndicators(.hidden)
        .textualPageHeader {
            TextualHeader(title: "UP NEXT", backLabel: "Back to My Archive",
                          backIdentifier: "archive.upNext.back",
                          backAction: { if let onBack { onBack() } else { dismiss() } }) {
                Button { showPicker = true } label: { DesignSystemIconView(.add) }
                    .buttonStyle(IconButtonStyle())
                    .accessibilityLabel("Add from your archive")
            }
        }
        .foregroundStyle(Color.paper).background(Color.inkwell.ignoresSafeArea())
        .buttonStyle(.plain).toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showPicker) {
            NavigationStack {
                ArchiveBooksView(choosingForQueue: true,
                    queuedIDs: Set(queue.map(\.id) + books.filter { $0.importedReading?.status == "currently-reading" }.map(\.id)),
                    chooseBook: { book in if save(queue + [book]) { showPicker = false } }, repository: repository,
                    onBack: { showPicker = false })
            }
        }
        .sheet(item: $selectedBook) { book in NavigationStack { BookDetailView(book: book, isPresentedAsSheet: true) } }
        .alert("Couldn’t save Up Next", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK") { saveError = nil }
        } message: { Text(saveError ?? "") }
    }

    @discardableResult
    private func save(_ books: [Book], removing: Book? = nil) -> Bool {
        do {
            try UpNextQueue.save(books, removing: removing, context: context, repository: repository)
            Task { await repository?.synchronize() }
            return true
        } catch { saveError = "Your reading queue couldn’t be saved. Please try again."; return false }
    }
}

/// The same quiet shelf line and dashed add-book tile used on the reader profile.
private struct ArchiveShelf: View {
    let books: [Book]
    var wraps = false
    var add: (() -> Void)? = nil
    var move: ((UUID, UUID) -> Void)? = nil
    var remove: ((Book) -> Void)? = nil
    var quickAction: ((Book, BookQuickAction) -> Void)? = nil
    let open: (Book) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var dropTarget: UUID?

    var body: some View {
        Group {
            if wraps {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], alignment: .leading, spacing: 24) {
                    tiles
                }.padding(.horizontal, TextualLayout.pageInset)
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .bottom, spacing: 12) { tiles }
                        .background(alignment: .bottom) { Rectangle().fill(Color.ghost.opacity(0.3)).frame(height: 6) }
                        .padding(.horizontal, TextualLayout.pageInset)
                }.scrollIndicators(.hidden)
            }
        }
    }

    @ViewBuilder private var tiles: some View {
        ForEach(books) { book in
            VStack(spacing: 8) {
                cover(book)
                Rectangle().fill(wraps ? Color.ghost.opacity(0.3) : Color.clear).frame(height: 6)
            }.frame(width: 100)
        }
        if let add {
            VStack(spacing: 8) {
                Button(action: add) {
                    RoundedRectangle(cornerRadius: TextualLayout.coverRadius).fill(Color.velvet.opacity(0.4))
                        .overlay { RoundedRectangle(cornerRadius: TextualLayout.coverRadius)
                            .strokeBorder(Color.ghost.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 4])) }
                        .overlay { DesignSystemIconView(.add, size: TextualIconStyle.shelfAdd.size).foregroundStyle(Color.ghost) }
                        .frame(width: 100, height: 155)
                }.accessibilityLabel("Add a book to Up Next").accessibilityHint("Choose from your archive")
                Rectangle().fill(wraps ? Color.ghost.opacity(0.3) : Color.clear).frame(height: 6)
            }.frame(width: 100)
        }
    }

    @ViewBuilder private func cover(_ book: Book) -> some View {
        let button = Button { open(book) } label: {
            SavedBookCover(book: book, width: 100, height: 155)
                .overlay { RoundedRectangle(cornerRadius: TextualLayout.coverRadius).strokeBorder(dropTarget == book.id ? Color.paper : Color.clear, lineWidth: 2) }
        }
        .accessibilityLabel("\(book.title), by \(book.author)")
        if let quickAction {
            HoldSlideSource(actions: BookQuickAction.allCases.map(\.menuAction),
                            isEnabled: scenePhase == .active,
                            open: { open(book) },
                            select: { id in
                                if let action = BookQuickAction(rawValue: id) { quickAction(book, action) }
                            }) {
                SavedBookCover(book: book, width: 100, height: 155)
            }
            .frame(width: 100, height: 155)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(book.title), by \(book.author)")
            .accessibilityHint("Double tap for reading details. Actions are also available.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open(book) }
            .accessibilityAction(named: "Save quote") { quickAction(book, .quote) }
            .accessibilityAction(named: "Update progress") { quickAction(book, .progress) }
            .accessibilityAction(named: "Finish and rate") { quickAction(book, .finish) }
            .accessibilityAction(named: "Add note") { quickAction(book, .note) }
            .accessibilityIdentifier("reading.book.\(book.id)")
        } else if let move {
            button.draggable(book.id.uuidString)
                .dropDestination(for: String.self) { items, _ in
                    guard items.count == 1, let id = items.first.flatMap(UUID.init(uuidString:)),
                          books.contains(where: { $0.id == id }) else { return false }
                    move(id, book.id)
                    return true
                } isTargeted: { dropTarget = $0 ? book.id : nil }
                .textualContextMenu {
                    Button("Move earlier") { moveBy(-1, book) }.disabled(books.first?.id == book.id)
                    Button("Move later") { moveBy(1, book) }.disabled(books.last?.id == book.id)
                    Button("Remove from Up Next", role: .destructive) { remove?(book) }
                }
                .accessibilityAction(named: "Move earlier") { moveBy(-1, book) }
                .accessibilityAction(named: "Move later") { moveBy(1, book) }
                .accessibilityAction(named: "Remove from Up Next") { remove?(book) }
        } else { button }
    }

    private func moveBy(_ offset: Int, _ book: Book) {
        guard let index = books.firstIndex(where: { $0.id == book.id }), books.indices.contains(index + offset) else { return }
        move?(book.id, books[index + offset].id)
    }
}
