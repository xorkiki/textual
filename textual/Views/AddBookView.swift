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
    @State private var choosingStatus: ArchiveStatusSelection?
    @State private var pendingAddition: (item: BookCatalogService.BookItem, status: BookAddStatus)?


    @State private var saveAlertTitle = "Couldn’t add book"
    @State private var saveErrorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.inkwell.ignoresSafeArea()
                VStack(spacing: 0) {
                    searchBar
                        .textualChromeBackground(edge: .top)
                        .zIndex(1)
                    searchContent
                }
            }
            .textualSheetHeader("Add Book") { dismiss() }
            .task {
                // Wait until the sheet is presented before opening the keyboard.
                do {
                    try await Task.sleep(for: .milliseconds(400))
                    isSearchFocused = true
                } catch { }
            }
            .onDisappear { viewModel.cancelSearch() }
            .sheet(item: $choosingStatus, onDismiss: {
                if let addition = pendingAddition {
                    pendingAddition = nil
                    saveBook(from: addition.item, status: addition.status)
                }
            }) { selection in
                ArchiveStatusChooser(title: viewModel.extractTitle(from: selection.item)) { status in
                    pendingAddition = (selection.item, status)
                    choosingStatus = nil
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.inkwell)
            }
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
        TextualSearchField(viewModel.searchPlaceholder, text: $viewModel.searchText,
                           focus: $isSearchFocused, onClear: viewModel.clearSearch,
                           onSubmit: viewModel.submitSearch)
            .onChange(of: viewModel.searchText) { _, _ in viewModel.searchTextDidChange() }
            .padding(.horizontal, TextualLayout.pageInset)
            .padding(.top, TextualLayout.itemGap)
            .padding(.bottom, TextualLayout.contentTop)
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
                DesignSystemIconView(.warning, size: TextualIconStyle.emptyState.size)
                    .foregroundColor(.ghost)
                Text("Search unavailable")
                    .textStyle(.heading3)
                    .foregroundColor(.paper)
                Text(error)
                    .textStyle(.bodyMedium)
                    .foregroundColor(.ghost)
                    .multilineTextAlignment(.center)
                Button("Try again") { viewModel.submitSearch() }
                    .buttonStyle(TextualButtonStyle())
                    .tint(.bloodletter)
            }
            .padding()
            Spacer()
        } else {
            Spacer()
            VStack(spacing: 8) {
                DesignSystemIconView(viewModel.hasSearched ? .bookPlaceholder : .search, size: TextualIconStyle.emptyState.size)
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
            Text("Tap to choose a status, or hold and slide to add.")
                .textStyle(.bodySmall).foregroundStyle(Color.ghost)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, TextualLayout.pageInset)
                .padding(.bottom, 8)
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(viewModel.searchResults, id: \.id) { item in
                        BookSearchResultRow(item: item, viewModel: viewModel,
                            onTap: {
                                isSearchFocused = false
                                choosingStatus = ArchiveStatusSelection(item: item)
                            }, onChooseStatus: { saveBook(from: item, status: $0) },
                            onHoldBegan: { isSearchFocused = false })
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
                    .buttonStyle(TextualButtonStyle(variant: .secondary))
                    .tint(.paper)
            }
            .padding(.vertical)
        } else if viewModel.canLoadMore {
            Button("Load more") { viewModel.loadMore() }
                .buttonStyle(TextualButtonStyle(variant: .secondary))
                .tint(.paper)
                .padding(.vertical)
        }
    }

    private func saveBook(from item: BookCatalogService.BookItem, status: BookAddStatus) {
        isSearchFocused = false
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
                saveErrorMessage = "This book has already been added. You can change its status in My Archive."
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
                try repository.add(book, status: status)
                Task { await repository.synchronize() }
            } else {
                try BookReadingActions.prepareArchiveStatus(status, for: book)
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
    let onChooseStatus: (BookAddStatus) -> Void
    var onHoldBegan: () -> Void = {}
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        rowWithOverlay
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(viewModel.extractTitle(from: item)), by \(viewModel.extractAuthor(from: item))")
            .accessibilityHint("Choose a status to add to your archive")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onTap() }
            .accessibilityAction(named: "Add as read") { onChooseStatus(.read) }
            .accessibilityAction(named: "Add as currently reading") { onChooseStatus(.currentlyReading) }
            .accessibilityAction(named: "Add as to be read") { onChooseStatus(.tbr) }
            .accessibilityAction(named: "Add as did not finish") { onChooseStatus(.dnf) }
            .accessibilityIdentifier("archive.search.\(item.id ?? "book")")
    }

    private var rowWithOverlay: some View {
        rowContent
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .overlay {
                HoldSlideSource(actions: BookAddStatus.allCases.map(\.menuAction),
                    isEnabled: isEnabled && scenePhase == .active,
                    open: onTap, select: { id in
                        if let status = BookAddStatus(rawValue: id) { onChooseStatus(status) }
                    }, onHoldBegan: onHoldBegan) { Color.clear }
            }
    }

    private var rowContent: some View {
        HStack(spacing: 16) {
            let coverURLString = viewModel.extractCoverURL(from: item)
            BookCoverImage(urlString: coverURLString, width: 60, height: 90,
                identity: BookCoverIdentity(title: viewModel.extractTitle(from: item),
                    author: viewModel.extractAuthor(from: item), isbn: viewModel.extractISBN(from: item),
                    catalogID: item.id))
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
            DesignSystemIconView(.add)
                .foregroundColor(.paper)
        }
    }
}

private struct ArchiveStatusSelection: Identifiable {
    let id = UUID()
    let item: BookCatalogService.BookItem
}

struct ArchiveStatusChooser: View {
    let title: String
    let select: (BookAddStatus) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).textStyle(.bodyMedium).foregroundStyle(Color.ghost)
                        .padding(.bottom, 8)
                    ForEach(BookAddStatus.allCases) { status in
                        Button { select(status) } label: {
                            HStack(spacing: 14) {
                                DesignSystemIconView(status.icon, size: 22)
                                Text(status.title).textStyle(.bodyMedium)
                                Spacer()
                            }
                            .foregroundStyle(Color.paper)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 52)
                            .background(Color.velvet, in: RoundedRectangle(cornerRadius: TextualLayout.cardRadius))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add as \(status.accessibleTitle)")
                        .accessibilityIdentifier("archive.add.\(status.rawValue)")
                    }
                }.padding(TextualLayout.pageInset)
            }
            .background(Color.inkwell.ignoresSafeArea())
            .textualSheetHeader("Add to archive") { dismiss() }
        }.preferredColorScheme(.dark)
    }
}

#Preview {
    AddBookView()
        .modelContainer(for: Book.self, inMemory: true)
}
