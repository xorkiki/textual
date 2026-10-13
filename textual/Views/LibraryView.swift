//
//  LibraryView.swift
//  textual
//
//  Created by kiki o on 1/26/26.
//

import SwiftUI
import SwiftData
import Nuke
import NukeUI

struct ArchiveBooksView: View {
    @Environment(\.dismiss) private var dismiss
    var choosingForQueue = false
    var queuedIDs: Set<UUID> = []
    var chooseBook: ((Book) -> Void)? = nil
    @State private var search = ""
    @Environment(\.readingLibrary) private var readingLibrary
    var repository: LibraryRepository? = nil
    var bottomNavigationInset: CGFloat = 0
    var onBack: (() -> Void)? = nil
    @State private var showConflicts = false
    @State private var libraryError: String?
    @Query(filter: #Predicate<Book> { !$0.isRemovedFromLibrary }, sort: \Book.title) private var books: [Book]
    @Environment(\.modelContext) private var modelContext
    @State private var showAddBook = false
    @State private var selectedBook: Book?
    @State private var syncBannerHeight: CGFloat = 0
    @State private var filter = ArchiveFilter(status: .all)
    @State private var sortOrder: ArchiveSort = .title

    private var bottomOverlayHeight: CGFloat {
        bottomNavigationInset + (repository?.message == nil ? 0 : syncBannerHeight + 8)
    }

    let columns = [
        GridItem(.adaptive(minimum: 120), spacing: 16, alignment: .top)
    ]

    var body: some View {
        let catalog = readingLibrary == nil ? ArchiveFilterCatalog(books: books) : nil
        let options = readingLibrary?.snapshot.archive.options ?? catalog!.options
        let ids = readingLibrary?.snapshot.archive.matching(filter, search: search, excluding: queuedIDs)
        let filteredBooks = (ids.map { ids in books.filter { ids.contains($0.id) } } ?? catalog!.books(matching: filter)).filter { book in
            !queuedIDs.contains(book.id) && (search.isEmpty || book.title.localizedStandardContains(search) || book.author.localizedStandardContains(search))
        }
        let visibleBooks = sortOrder.sorted(filteredBooks)
        Group {
            ZStack {
                // Background
                Color.inkwell
                    .ignoresSafeArea()

                ScrollView {
                    if books.isEmpty {
                        TextualEmptyState(title: "Your archive starts here", icon: .archive,
                            detail: choosingForQueue ? "Add books to your archive first, then choose your next read here." : "Tap + to find and save your first book.")
                            .foregroundStyle(Color.paper)
                            .padding(.top, TextualLayout.contentTop)
                            .padding(.bottom, bottomOverlayHeight + 12)
                    } else if visibleBooks.isEmpty {
                        TextualEmptyState(title: "No matching books", icon: .search,
                            detail: choosingForQueue ? "Try another filter or search. Books already in Up Next or Currently Reading are left out." : "Try another reading status or change your filters.")
                            .foregroundStyle(Color.paper)
                            .padding(.top, TextualLayout.contentTop)
                            .padding(.bottom, bottomOverlayHeight + 12)
                    } else {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(visibleBooks) { book in
                                Button {
                                    if let chooseBook { chooseBook(book) } else { selectedBook = book }
                                } label: {
                                    BookGridItem(book: book)
                                }
                                .buttonStyle(.plain)
                                .textualContextMenu(isEnabled: !choosingForQueue) {
                                    if !choosingForQueue { Button(role: .destructive) {
                                        deleteBook(book)
                                    } label: {
                                        Label("Delete", textualIcon: .remove)
                                    } }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, TextualLayout.contentTop)
                        .padding(.bottom, bottomOverlayHeight + 12)
                    }
                }
                .scrollIndicators(.hidden)
                .clipped()
                .refreshable { await repository?.synchronize() }

            }
            .textualPageHeader { libraryHeader(options: options) }
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
                    .padding()
                    .textualChromeBackground(edge: .bottom, fadeInside: true)
                    .tint(.paper)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { syncBannerHeight = $0 }
                    .padding(.bottom, bottomNavigationInset + 8)
                }
            }
            .textualDropdownHost()
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: options) { _, options in
                if readingLibrary == nil || readingLibrary?.isReady == true { filter.reconcile(with: options) }
            }
            .sheet(isPresented: $showAddBook) {
                AddBookView(repository: repository)
            }
            .sheet(isPresented: $showConflicts) {
                if let repository { LibraryConflictsView(repository: repository) }
            }
            .alert("Couldn’t update library", isPresented: Binding(
                get: { libraryError != nil }, set: { if !$0 { libraryError = nil } }
            )) {
                Button("OK") { libraryError = nil }
            } message: { Text(libraryError ?? "") }
            .sheet(item: $selectedBook) { book in
                NavigationStack {
                    BookDetailView(book: book, isPresentedAsSheet: true, showsReadingActivity: true)
                }
            }
        }
    }

    private func libraryHeader(options: ArchiveFilterOptions) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            TextualHeader(title: choosingForQueue ? "ADD TO UP NEXT" : "ALL BOOKS",
                          titleIdentifier: "archive.header",
                          backAction: choosingForQueue ? nil : { if let onBack { onBack() } else { dismiss() } }) {
                if choosingForQueue {
                    TextualCloseButton { if let onBack { onBack() } else { dismiss() } }
                } else {
                    Button { showAddBook = true } label: { DesignSystemIconView(.add) }
                        .buttonStyle(IconButtonStyle())
                        .accessibilityLabel("Add a book")
                }
            }
            TextualSearchField("Search your archive", text: $search)
                .padding(.horizontal, TextualLayout.pageInset)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    filterMenus(options: options)
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, TextualLayout.pageInset)
            }
            .fixedSize(horizontal: false, vertical: true)
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .accessibilityIdentifier("archive.filters")
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func filterMenus(options: ArchiveFilterOptions) -> some View {
        TextualDropdown(label: "Reading status", title: filter.status.title,
            options: ArchiveReadingStatus.allCases.map {
                TextualDropdownOption(value: $0, title: $0.title, accessibilityTitle: $0.accessibleTitle)
            }, selection: $filter.status)
            .accessibilityIdentifier("archive.status")
        TextualDropdown(label: "Sort books", title: sortOrder.title,
            options: ArchiveSort.allCases.map { TextualDropdownOption(value: $0, title: $0.title) },
            selection: $sortOrder)
            .accessibilityIdentifier("archive.sort")
        metadataMenu("Genre", allTitle: "All genres", options: options.genres, selection: $filter.genre)
        metadataMenu("Mood", allTitle: "All moods", options: options.moods, selection: $filter.mood)
        metadataMenu("Pace", allTitle: "All paces", options: options.paces, selection: $filter.pace)
    }

    private func metadataMenu(_ title: String, allTitle: String, options: [String], selection: Binding<String?>) -> some View {
        TextualDropdown(label: title, title: selection.wrappedValue ?? title,
            options: [TextualDropdownOption(value: String?.none, title: allTitle)]
                + options.map { TextualDropdownOption(value: Optional($0), title: $0) },
            selection: selection)
            .accessibilityIdentifier("archive.\(title.lowercased())")
    }

    private func deleteBook(_ book: Book) {
        do {
            if let repository {
                try repository.remove(book)
                Task { await repository.synchronize() }
            } else {
                modelContext.delete(book)
                try modelContext.save()
            }
        } catch {
            modelContext.rollback()
            libraryError = "Your book couldn’t be removed. Please try again."
        }
    }

}

struct BookGridItem: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SavedBookCover(book: book, width: 120, height: 180)

            // Title
            Text(book.title)
                .textStyle(.bodyMedium)
                .foregroundColor(.paper)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)

            // Author
            Text(book.author)
                .textStyle(.bodySmall)
                .foregroundColor(.ghost)
                .lineLimit(1)
        }
        .frame(width: 120)
    }
}

/// Uses cached catalog metadata before asking a provider for another cover.
struct SavedBookCover: View {
    let book: Book
    let width: CGFloat
    let height: CGFloat
    var fetchedURL: String = ""

    var body: some View {
        BookCoverImage(urlString: book.coverCandidates.first ?? "", width: width, height: height,
                       identity: BookCoverIdentity(book: book),
                       alternateURLs: Array(book.coverCandidates.dropFirst()) + [fetchedURL],
                       onResolved: { book.rememberCover($0) })
    }
}

/// Shared image caching, bounded fallback, and cancellation when a cover scrolls away.
struct BookCoverImage: View {
    let urlString: String
    let width: CGFloat
    let height: CGFloat
    var identity: BookCoverIdentity? = nil
    var alternateURLs: [String] = []
    var onResolved: ((String) -> Void)? = nil
    @State private var loader = BookCoverLoader()

    private static let pipeline = ImagePipeline(
        configuration: .withDataCache(name: "kiki.textual.covers", sizeLimit: 100 * 1024 * 1024)
    )

    static func imageRequest(_ value: String, width: CGFloat, height: CGFloat, cacheOnly: Bool = false) -> Nuke.ImageRequest? {
        guard let normalized = BookCoverURL.normalized(value), let url = URL(string: normalized) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("Textual/1.0 (https://github.com/xorkiki/textual)", forHTTPHeaderField: "User-Agent")
        var imageRequest = Nuke.ImageRequest(urlRequest: request, userInfo: [
            .imageIdKey: BookCoverURL.cacheIdentity(normalized),
            .thumbnailKey: Nuke.ImageRequest.ThumbnailOptions(
                size: CGSize(width: width, height: height), unit: .points, contentMode: .aspectFill)
        ])
        if cacheOnly { imageRequest.options.insert(.returnCacheDataDontLoad) }
        return imageRequest
    }

    /// Use decoded memory only during rendering. Disk reads and decoding stay
    /// in the asynchronous pipeline, never on a drag animation's main thread.
    static func cachedImage(urls: [String], width: CGFloat, height: CGFloat, pipeline: ImagePipeline) -> UIImage? {
        for value in urls {
            guard let request = imageRequest(value, width: width, height: height),
                  let image = pipeline.cache.cachedImage(for: request, caches: [.memory])?.image,
                  image.size.width > 8, image.size.height > 8 else { continue }
            return image
        }
        return nil
    }

    private struct LoadKey: Hashable {
        let urls: [String]
        let identity: BookCoverIdentity?
        let width: CGFloat
        let height: CGFloat
    }

    var body: some View {
        let key = LoadKey(urls: [urlString] + alternateURLs, identity: identity, width: width, height: height)
        ZStack {
            if let image = loader.image ?? Self.cachedImage(urls: key.urls, width: width, height: height, pipeline: Self.pipeline) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Color.coverPlaceholder)
                    .overlay {
                        if loader.isLoading {
                            ProgressView().tint(.paper)
                        } else {
                            DesignSystemIconView(.bookPlaceholder).foregroundColor(.ghost)
                        }
                    }
            }
        }
        .frame(width: width, height: height)
        .cornerRadius(TextualLayout.coverRadius)
        .clipped()
        .shadow(color: .inkwell.opacity(0.1), radius: 4, x: 0, y: 2)
        .task(id: key) {
            let workingURL = await loader.load(urls: key.urls, identity: key.identity, cachedImageLoader: { value in
                guard let request = Self.imageRequest(value, width: width, height: height, cacheOnly: true) else {
                    throw URLError(.badURL)
                }
                return try await Self.pipeline.image(for: request)
            }, imageLoader: { value in
                guard let request = Self.imageRequest(value, width: width, height: height) else { throw URLError(.badURL) }
                return try await Self.pipeline.image(for: request)
            }, replacements: { try await BookCatalogService.shared.replacementCoverURLs(for: $0) },
               secondaryReplacements: { try await BookCatalogService.shared.replacementCoverURLs(for: $0, provider: .google) })
            if !Task.isCancelled, let workingURL { onResolved?(workingURL) }
        }
    }
}

#Preview {
    LibraryView()
        .modelContainer(for: Book.self, inMemory: true)
}
