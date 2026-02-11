//
//  AddBookView.swift
//  textual
//
//  Created by kiki o on 1/26/26.
//

import SwiftUI
import SwiftData

struct AddBookView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isSearchFocused: Bool
    @State private var viewModel = AddBookViewModel()
    
    // Dummy UUID for testing before Auth flow
    private let dummyUserId = UUID()
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                Color.inkwell
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Search Bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.ghost)
                        
                        TextField("Search by title or author", text: $viewModel.searchText)
                            .textStyle(.bodyMedium)
                            .foregroundColor(.paper)
                            .textFieldStyle(.plain)
                            .focused($isSearchFocused)
                            .onChange(of: viewModel.searchText) { oldValue, newValue in
                                // Debounce search - search after user stops typing
                                Task {
                                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second delay
                                    if viewModel.searchText == newValue {
                                        await viewModel.performSearch()
                                    }
                                }
                            }
                            .onSubmit {
                                Task {
                                    await viewModel.performSearch()
                                }
                            }
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                        
                        if !viewModel.searchText.isEmpty {
                            Button(action: {
                                viewModel.searchText = ""
                                viewModel.searchResults = []
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.ghost)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.velvet.opacity(0.3))
                    .cornerRadius(10)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    
                    // Results List
                    if viewModel.isSearching {
                        Spacer()
                        ProgressView()
                            .tint(.paper)
                            .padding()
                        Spacer()
                    } else if let error = viewModel.errorMessage {
                        Spacer()
                        Text(error)
                            .textStyle(.bodyMedium)
                            .foregroundColor(.ghost)
                            .padding()
                        Spacer()
                    } else if viewModel.searchResults.isEmpty && !viewModel.searchText.isEmpty {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "book.closed")
                                .font(.system(size: 48))
                                .foregroundColor(.ghost)
                            Text("No results found")
                                .textStyle(.heading3)
                                .foregroundColor(.paper)
                        }
                        .padding()
                        Spacer()
                    } else if viewModel.searchResults.isEmpty {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 48))
                                .foregroundColor(.ghost)
                            Text("Search for books")
                                .textStyle(.heading3)
                                .foregroundColor(.paper)
                            Text("Enter a title or author name")
                                .textStyle(.bodyMedium)
                                .foregroundColor(.ghost)
                        }
                        .padding()
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 16) {
                                ForEach(viewModel.searchResults, id: \.id) { item in
                                    BookSearchResultRow(
                                        item: item,
                                        viewModel: viewModel,
                                        onTap: {
                                            saveBook(from: item)
                                        }
                                    )
                                }
                            }
                            .padding()
                        }
                    }
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
                    Button("Done") {
                        dismiss()
                    }
                    .textStyle(.uiButton)
                    .foregroundColor(.paper)
                }
            }
            .onAppear {
                // Focus search field when sheet appears so keyboard shows reliably
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    isSearchFocused = true
                }
            }
        }
    }
    
    private func saveBook(from item: GoogleBooksService.BookItem) {
        let title = viewModel.extractTitle(from: item)
        let isbn = viewModel.extractISBN(from: item)
        let coverURL = viewModel.extractCoverURL(from: item)
        let author = viewModel.extractAuthor(from: item)
        
        let book = Book(
            title: title,
            author: author,
            isbn: isbn.isEmpty ? (item.id ?? UUID().uuidString) : isbn,
            coverURL: coverURL,
            googleBooksVolumeId: item.id
        )
        
        modelContext.insert(book)
        
        do {
            try modelContext.save()
            dismiss()
        } catch {
            print("Failed to save book: \(error.localizedDescription)")
        }
    }
}

struct BookSearchResultRow: View {
    let item: GoogleBooksService.BookItem
    let viewModel: AddBookViewModel
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                // Cover Image (URLSession with User-Agent so Google Books accepts the request)
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
