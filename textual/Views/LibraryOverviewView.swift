import SwiftUI
import SwiftData

struct LibraryView: View {
    var repository: LibraryRepository? = nil
    var bottomNavigationInset: CGFloat = 0
    @Query(filter: #Predicate<Book> { !$0.isRemovedFromLibrary }, sort: \Book.title) private var books: [Book]
    private enum Destination: Hashable { case upNext, allBooks }
    @State private var path: [Destination] = []
    @State private var selectedBook: Book?
    @State private var showAddBook = false
    @State private var showQueuePicker = false
    @State private var saveError: String?
    @State private var showConflicts = false
    @Environment(\.modelContext) private var context

    private var currentlyReading: [Book] { books.filter { $0.importedReading?.status == "currently-reading" } }
    private var queue: [Book] { UpNextQueue.books(in: books) }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Currently reading").archiveHeading().padding(.horizontal, 24)
                        if currentlyReading.isEmpty {
                            Text("Your current reads will have a place here.")
                                .textStyle(.bodySmall).foregroundStyle(Color.ghost)
                                .padding(.horizontal, 24)
                        } else {
                            ArchiveShelf(books: currentlyReading, open: { selectedBook = $0 })
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
                            }.padding(.horizontal, 24)
                        }.contentShape(Rectangle())
                    }.accessibilityLabel("All books, \(books.count) books. Browse your archive")
                }
                .padding(.top, 12)
                .padding(.bottom, bottomNavigationInset + 24)
            }
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .upNext:
                    UpNextView(repository: repository, bottomNavigationInset: bottomNavigationInset,
                        onBack: { path.removeAll() })
                case .allBooks:
                    ArchiveBooksView(repository: repository, bottomNavigationInset: bottomNavigationInset,
                        onBack: { path.removeAll() })
                }
            }
            .scrollIndicators(.hidden)
            .textualPageHeader(compact: true) {
                HStack {
                    Text("MY ARCHIVE").archiveHeading()
                    Spacer()
                    Button { showAddBook = true } label: {
                        Image(systemName: "plus").frame(width: 44, height: 44)
                    }.accessibilityLabel("Add a book")
                }
                .padding(.horizontal, 24)
                .accessibilityIdentifier("archive.header")
            }
            .background(Color.inkwell.ignoresSafeArea())
            .foregroundStyle(Color.paper)
            .buttonStyle(.plain)
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await repository?.synchronize() }
            .overlay(alignment: .bottom) {
                if let repository, let message = repository.message {
                    HStack(spacing: 12) {
                        Text(message).font(.caption).foregroundStyle(Color.paper)
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
            .sheet(item: $selectedBook) { book in NavigationStack { BookDetailView(book: book) } }
            .alert("Couldn’t save Up Next", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK") { saveError = nil }
            } message: { Text(saveError ?? "") }
        }
    }

    private func sectionHeading(_ title: String, count: Int) -> some View {
        HStack(spacing: 12) {
            Text(title).archiveHeading()
            Spacer()
            Text("\(count)").textStyle(.bodySmall).foregroundStyle(Color.ghost)
            DesignSystemIconView(.arrowRight, size: 20, color: .ghost).accessibilityHidden(true)
        }.padding(.horizontal, 24).contentShape(Rectangle())
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
                Text(queue.isEmpty ? "Choose your next read from your archive." : "Drag your books into the order you want to read them.")
                    .textStyle(.bodySmall).foregroundStyle(Color.ghost).padding(.horizontal, 24)
                ArchiveShelf(books: queue, wraps: true, add: { showPicker = true },
                    move: { id, target in save(UpNextQueue.moving(id, to: target, in: queue)) },
                    remove: { book in save(queue.filter { $0.id != book.id }, removing: book) },
                    open: { selectedBook = $0 })
            }
            .padding(.top, 24).padding(.bottom, bottomNavigationInset + 24)
        }
        .scrollIndicators(.hidden)
        .textualPageHeader {
            HStack {
                TextualBackButton(label: "Back to My Archive") {
                    if let onBack { onBack() } else { dismiss() }
                }
                    .accessibilityIdentifier("archive.upNext.back")
                Text("UP NEXT").archiveHeading()
                Spacer()
                Button { showPicker = true } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                    .accessibilityLabel("Add from your archive")
            }.padding(.horizontal, 24)
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
        .sheet(item: $selectedBook) { book in NavigationStack { BookDetailView(book: book) } }
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
    let open: (Book) -> Void
    @State private var dropTarget: UUID?

    var body: some View {
        Group {
            if wraps {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], alignment: .leading, spacing: 24) {
                    tiles
                }.padding(.horizontal, 24)
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .bottom, spacing: 12) { tiles }
                        .background(alignment: .bottom) { Rectangle().fill(Color.ghost.opacity(0.3)).frame(height: 6) }
                        .padding(.horizontal, 24)
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
                    RoundedRectangle(cornerRadius: 8).fill(Color.velvet.opacity(0.4))
                        .overlay { RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.ghost.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 4])) }
                        .overlay { Image(systemName: "plus").font(.system(size: 23, weight: .light)).foregroundStyle(Color.ghost) }
                        .frame(width: 100, height: 155)
                }.accessibilityLabel("Add a book to Up Next").accessibilityHint("Choose from your archive")
                Rectangle().fill(wraps ? Color.ghost.opacity(0.3) : Color.clear).frame(height: 6)
            }.frame(width: 100)
        }
    }

    @ViewBuilder private func cover(_ book: Book) -> some View {
        let button = Button { open(book) } label: {
            SavedBookCover(book: book, width: 100, height: 155)
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(dropTarget == book.id ? Color.paper : Color.clear, lineWidth: 2) }
        }
        .accessibilityLabel("\(book.title), by \(book.author)")
        if let move {
            button.draggable(book.id.uuidString)
                .dropDestination(for: String.self) { items, _ in
                    guard items.count == 1, let id = items.first.flatMap(UUID.init(uuidString:)),
                          books.contains(where: { $0.id == id }) else { return false }
                    move(id, book.id)
                    return true
                } isTargeted: { dropTarget = $0 ? book.id : nil }
                .contextMenu {
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

private extension Text {
    func archiveHeading() -> some View {
        font(.custom("CormorantGaramond-Regular", size: 28, relativeTo: .title2))
            .foregroundStyle(Color.paper).accessibilityAddTraits(.isHeader)
    }
}
