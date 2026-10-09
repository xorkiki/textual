//
//  AddBookView.swift
//  textual
//
//  Created by kiki o on 1/26/26.
//

import SwiftUI
import SwiftData

struct AddBookView: View {
    var repository: LibraryRepository? = nil
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isSearchFocused: Bool
    @State private var viewModel = AddBookViewModel()

    @State private var saveAlertTitle = "Couldn’t add book"
    @State private var saveErrorMessage: String?
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.inkwell.ignoresSafeArea()
                VStack(spacing: 0) {
                    searchBar
                    searchContent
                }
            }
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color.inkwell, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Add Book")
                        .font(.custom("CormorantGaramond-Regular", size: 28))
                        .textCase(.uppercase)
                        .foregroundColor(.paper)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .textStyle(.uiButton)
                        .foregroundColor(.paper)
                }
            }
            .task {
                // Wait until the sheet is presented before opening the keyboard.
                do {
                    try await Task.sleep(for: .milliseconds(400))
                    isSearchFocused = true
                } catch { }
            }
            .onDisappear { viewModel.cancelSearch() }
            .alert(saveAlertTitle, isPresented: Binding(
                get: { saveErrorMessage != nil },
                set: { if !$0 { saveErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { saveErrorMessage = nil }
            } message: {
                Text(saveErrorMessage ?? "")
            }
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.ghost)
            TextField(viewModel.searchPlaceholder, text: $viewModel.searchText)
                .textStyle(.bodyMedium)
                .foregroundColor(.paper)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onChange(of: viewModel.searchText) { _, _ in
                    viewModel.searchTextDidChange()
                }
                .onSubmit { viewModel.submitSearch() }
                .submitLabel(.search)
                .autocapitalization(.none)
                .autocorrectionDisabled()

            if !viewModel.searchText.isEmpty {
                Button(action: viewModel.clearSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.ghost)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.velvet.opacity(0.3), in: Capsule())
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var searchContent: some View {
        if !viewModel.searchResults.isEmpty {
            resultsList
        } else if viewModel.isSearching {
            Spacer()
            ProgressView("Searching books…")
                .tint(.paper)
                .foregroundStyle(Color.ghost)
                .padding()
            Spacer()
        } else if let error = viewModel.errorMessage {
            Spacer()
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 40))
                    .foregroundColor(.ghost)
                Text("Search unavailable")
                    .textStyle(.heading3)
                    .foregroundColor(.paper)
                Text(error)
                    .textStyle(.bodyMedium)
                    .foregroundColor(.ghost)
                    .multilineTextAlignment(.center)
                Button("Try again") { viewModel.submitSearch() }
                    .buttonStyle(.borderedProminent)
                    .tint(.bloodletter)
            }
            .padding()
            Spacer()
        } else {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: viewModel.hasSearched ? "book.closed" : "magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundColor(.ghost)
                Text(viewModel.hasSearched ? "No results found" : "Search for books")
                    .textStyle(.heading3)
                    .foregroundColor(.paper)
                Text(searchHint)
                    .textStyle(.bodyMedium)
                    .foregroundColor(.ghost)
                    .multilineTextAlignment(.center)
            }
            .padding()
            Spacer()
        }
    }

    private var searchHint: String {
        if viewModel.isQueryTooShort {
            return "Enter at least \(BookCatalogService.minimumSearchQueryLength) characters to search by title or author."
        }
        return viewModel.hasSearched ? "Try another title or author name" : "Enter a title or author name"
    }

    private var resultsList: some View {
        VStack(spacing: 0) {
            if viewModel.isSearching {
                HStack(spacing: 8) {
                    ProgressView().tint(.paper)
                    Text("Updating results…")
                        .textStyle(.bodySmall)
                        .foregroundColor(.ghost)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(viewModel.searchResults, id: \.id) { item in
                        BookSearchResultRow(item: item, viewModel: viewModel) {
                            saveBook(from: item)
                        }
                        .disabled(viewModel.isSearching)
                        .opacity(viewModel.isSearching ? 0.6 : 1)
                    }
                    paginationFooter
                }
                .padding()
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    @ViewBuilder
    private var paginationFooter: some View {
        if viewModel.isLoadingMore {
            ProgressView("Loading more books…")
                .tint(.paper)
                .foregroundStyle(Color.ghost)
                .padding()
        } else if let error = viewModel.paginationErrorMessage {
            VStack(spacing: 12) {
                Text(error)
                    .textStyle(.bodySmall)
                    .foregroundColor(.ghost)
                    .multilineTextAlignment(.center)
                Button("Try loading more") { viewModel.loadMore() }
                    .buttonStyle(.bordered)
                    .tint(.paper)
            }
            .padding(.vertical)
        } else if viewModel.canLoadMore {
            Button("Load more") { viewModel.loadMore() }
                .buttonStyle(.bordered)
                .tint(.paper)
                .padding(.vertical)
        }
    }

    private func saveBook(from item: BookCatalogService.BookItem) {
        let title = viewModel.extractTitle(from: item)
        let extractedISBN = viewModel.extractISBN(from: item)
        let isbn = extractedISBN.isEmpty ? (item.id ?? UUID().uuidString) : extractedISBN
        let coverURL = viewModel.extractCoverURL(from: item)
        let author = viewModel.extractAuthor(from: item)
        let providerID = item.id

        do {
            var duplicates = FetchDescriptor<Book>(predicate: #Predicate<Book> { book in
                !book.isRemovedFromLibrary && (book.isbn == isbn || (providerID != nil && book.googleBooksVolumeId == providerID))
            })
            duplicates.fetchLimit = 1
            guard try modelContext.fetch(duplicates).isEmpty else {
                saveAlertTitle = "Already in your library"
                saveErrorMessage = "This book has already been added. You can find it in My Library."
                return
            }
        } catch {
            saveAlertTitle = "Couldn’t add book"
            saveErrorMessage = "Your library couldn’t be checked. Please try again."
            return
        }

        let book = Book(
            title: title,
            author: author,
            isbn: isbn,
            coverURL: coverURL,
            googleBooksVolumeId: providerID
        )
        do {
            if let repository {
                try repository.add(book)
                Task { await repository.synchronize() }
            } else {
                modelContext.insert(book)
                try modelContext.save()
            }
            dismiss()
        } catch {
            modelContext.rollback()
            saveAlertTitle = "Couldn’t add book"
            saveErrorMessage = "The book couldn’t be saved to your library. Please try again."
        }
    }

}

struct BookSearchResultRow: View {
    let item: BookCatalogService.BookItem
    let viewModel: AddBookViewModel
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                // Cover image
                let coverURLString = viewModel.extractCoverURL(from: item)
                if !coverURLString.isEmpty {
                    BookCoverImage(urlString: coverURLString, width: 60, height: 90)
                } else {
                    Rectangle()
                        .fill(Color.velvet.opacity(0.3))
                        .frame(width: 60, height: 90)
                        .overlay {
                            Image(systemName: "book.closed")
                                .foregroundColor(.ghost)
                        }
                        .cornerRadius(4)
                }
                
                // Title and Author
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.extractTitle(from: item))
                        .textStyle(.bodyLarge)
                        .foregroundColor(.paper)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    
                    Text(viewModel.extractAuthor(from: item))
                        .textStyle(.bodySmall)
                        .foregroundColor(.ghost)
                        .lineLimit(1)
                }
                
                Spacer()
                
                Image(systemName: "plus.circle.fill")
                    .foregroundColor(.bloodletter)
                    .font(.system(size: 24))
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    AddBookView()
        .modelContainer(for: Book.self, inMemory: true)
}
