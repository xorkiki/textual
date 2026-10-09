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

struct LibraryView: View {
    var repository: LibraryRepository? = nil
    var bottomNavigationInset: CGFloat = 0
    @State private var showConflicts = false
    @State private var libraryError: String?
    @Query(filter: #Predicate<Book> { !$0.isRemovedFromLibrary }, sort: \Book.title) private var books: [Book]
    @Environment(\.modelContext) private var modelContext
    @State private var showAddBook = false
    @State private var selectedBook: Book?
    @State private var syncBannerHeight: CGFloat = 0
    private let headerHeight: CGFloat = 60

    private var bottomOverlayHeight: CGFloat {
        bottomNavigationInset + (repository?.message == nil ? 0 : syncBannerHeight + 8)
    }

    let columns = [
        GridItem(.adaptive(minimum: 120), spacing: 16, alignment: .top)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                Color.inkwell
                    .ignoresSafeArea()

                ScrollView {
                    if books.isEmpty {
                        ContentUnavailableView("Your archive starts here", systemImage: "books.vertical",
                            description: Text("Tap + to find and save your first book."))
                            .foregroundStyle(Color.paper)
                            .padding(.top, headerHeight + 8)
                            .padding(.bottom, bottomOverlayHeight + 12)
                    } else {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(books) { book in
                                Button {
                                    selectedBook = book
                                } label: {
                                    BookGridItem(book: book)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        deleteBook(book)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, headerHeight + 8)
                        .padding(.bottom, bottomOverlayHeight + 12)
                    }
                }
                .scrollIndicators(.hidden)
                .clipped()
                .refreshable { await repository?.synchronize() }

                // The books continue behind the controls. Only their overlapping
                // regions fade; the central reading area remains fully visible.
                VStack(spacing: 0) {
                    LinearGradient(stops: [
                        .init(color: .inkwell, location: 0),
                        .init(color: .inkwell.opacity(0.92), location: 0.55),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                    .frame(height: headerHeight + 12)
                    Spacer(minLength: 0)
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .inkwell.opacity(0.9), location: 0.7),
                        .init(color: .inkwell, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                    .frame(height: bottomOverlayHeight + 12)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .overlay(alignment: .top) { libraryHeader }
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
                    .padding()
                    .background(Color.inkwell)
                    .tint(.paper)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { syncBannerHeight = $0 }
                    .padding(.bottom, bottomNavigationInset + 8)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
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
                    BookDetailView(book: book)
                }
            }
        }
    }

    private var libraryHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
            Text("My Archive")
                .font(.custom("CormorantGaramond-Regular", size: 28))
                .textCase(.uppercase)
                .foregroundStyle(Color.paper)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            Button { showAddBook = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(Color.paper)
                    .frame(width: 44, height: 44)
                    .background(Color.velvet, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add a book")
        }
        .padding(.horizontal, 16)
        .frame(height: headerHeight)
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
            // Cached, downsampled book cover
            if !book.coverURL.isEmpty {
                BookCoverImage(urlString: book.coverURL, width: 120, height: 180)
            } else {
                Rectangle()
                    .fill(Color.velvet.opacity(0.3))
                    .frame(width: 120, height: 180)
                    .overlay {
                        Image(systemName: "book.closed")
                            .foregroundColor(.ghost)
                            .font(.system(size: 32))
                    }
                    .cornerRadius(8)
                    .shadow(color: .inkwell.opacity(0.1), radius: 4, x: 0, y: 2)
            }
            
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

/// Loads covers with shared disk/memory caching and cancels offscreen requests.
struct BookCoverImage: View {
    let urlString: String
    let width: CGFloat
    let height: CGFloat

    private static let pipeline = ImagePipeline(
        configuration: .withDataCache(
            name: "kiki.textual.covers",
            sizeLimit: 100 * 1024 * 1024
        )
    )

    private var request: Nuke.ImageRequest? {
        guard !urlString.isEmpty, let url = URL(string: urlString) else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        return Nuke.ImageRequest(
            urlRequest: request,
            userInfo: [
                .thumbnailKey: Nuke.ImageRequest.ThumbnailOptions(
                    size: CGSize(width: width, height: height),
                    unit: .points,
                    contentMode: .aspectFill
                )
            ]
        )
    }

    var body: some View {
        LazyImage(request: request) { state in
            if let image = state.image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.velvet.opacity(0.3))
                    .overlay {
                        if state.isLoading {
                            ProgressView().tint(.paper)
                        } else {
                            Image(systemName: "book.closed")
                                .foregroundColor(.ghost)
                        }
                    }
            }
        }
        .pipeline(Self.pipeline)
        .id("\(width)x\(height)")
        .frame(width: width, height: height)
        .cornerRadius(8)
        .clipped()
        .shadow(color: .inkwell.opacity(0.1), radius: 4, x: 0, y: 2)
    }
}

#Preview {
    LibraryView()
        .modelContainer(for: Book.self, inMemory: true)
}
