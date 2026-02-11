//
//  LibraryView.swift
//  textual
//
//  Created by kiki o on 1/26/26.
//

import SwiftUI
import SwiftData

struct LibraryView: View {
    @Query(sort: \Book.title) private var books: [Book]
    @Environment(\.modelContext) private var modelContext
    @State private var showAddBook = false
    @State private var selectedBook: Book?

    let columns = [
        GridItem(.adaptive(minimum: 120), spacing: 16)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                Color.inkwell
                    .ignoresSafeArea()

                ScrollView {
                    if books.isEmpty {
                        // Empty state - blank but navigation/toolbar still visible
                        Spacer()
                            .frame(height: 100)
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
                        .padding()
                    }
                }
            }
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color.inkwell, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("My Library")
                        .font(.custom("CormorantGaramond-Regular", size: 28))
                        .textCase(.uppercase)
                        .foregroundColor(.paper)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showAddBook = true
                    } label: {
                        Image(systemName: "plus")
                            .foregroundColor(.paper)
                            .font(.system(size: 20, weight: .medium))
                    }
                }
            }
            .sheet(isPresented: $showAddBook) {
                AddBookView()
            }
            .sheet(item: $selectedBook) { book in
                NavigationStack {
                    BookDetailView(book: book)
                }
            }
        }
    }
    
    private func deleteBook(_ book: Book) {
        modelContext.delete(book)
        do {
            try modelContext.save()
        } catch {
            print("Failed to delete book: \(error.localizedDescription)")
        }
    }
}

struct BookGridItem: View {
    let book: Book
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Cover Image
            if let coverURL = URL(string: book.coverURL), !book.coverURL.isEmpty {
                AsyncImage(url: coverURL) { phase in
                    switch phase {
                    case .empty:
                        Rectangle()
                            .fill(Color.velvet.opacity(0.3))
                            .overlay {
                                ProgressView()
                                    .tint(.paper)
                            }
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        Rectangle()
                            .fill(Color.velvet.opacity(0.3))
                            .overlay {
                                Image(systemName: "book.closed")
                                    .foregroundColor(.ghost)
                            }
                    @unknown default:
                        Rectangle()
                            .fill(Color.velvet.opacity(0.3))
                    }
                }
                .frame(width: 120, height: 180)
                .cornerRadius(8)
                .clipped()
                .shadow(color: .inkwell.opacity(0.1), radius: 4, x: 0, y: 2)
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
                .lineLimit(2)
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

#Preview {
    LibraryView()
        .modelContainer(for: Book.self, inMemory: true)
}
