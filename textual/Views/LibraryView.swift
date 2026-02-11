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
            // Cover Image (URLSession with User-Agent so Google Books accepts the request)
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

/// Limits concurrent Google Books image requests and caches results to avoid 429 rate limiting.
private actor BookCoverImageLoader {
    static let shared = BookCoverImageLoader()
    private var cache: [String: UIImage] = [:]
    private var inFlight = 0
    private let maxConcurrent = 3
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func cached(_ urlString: String) -> UIImage? {
        cache[urlString]
    }

    func setCached(_ urlString: String, _ image: UIImage) {
        cache[urlString] = image
    }

    func beginLoad() async {
        while inFlight >= maxConcurrent {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                waiters.append(cont)
            }
        }
        inFlight += 1
    }

    func endLoad() {
        inFlight -= 1
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        }
    }

    func load(urlString: String) async -> UIImage? {
        if let cached = cache[urlString] { return cached }
        await beginLoad()
        defer { endLoad() }
        guard let url = URL(string: urlString), !urlString.isEmpty else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        do {
            var (data, response) = try await URLSession.shared.data(for: request)
            var statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if statusCode == 429 {
                try await Task.sleep(nanoseconds: 1_500_000_000)
                let retry = try await URLSession.shared.data(for: request)
                data = retry.0
                response = retry.1
                statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            }
            if let uiImage = UIImage(data: data) {
                cache[urlString] = uiImage
                return uiImage
            }
            return nil
        } catch {
            return nil
        }
    }
}

/// Loads a book cover from URL with a browser User-Agent (Google Books blocks default requests).
/// Uses shared cache and limits concurrency to avoid 429 rate limiting.
/// Retries on failure (with delay) and on reappear so we don't give up after one miss.
struct BookCoverImage: View {
    let urlString: String
    let width: CGFloat
    let height: CGFloat
    @State private var image: UIImage?
    @State private var loadFailed = false
    @State private var retryAttempt = 0

    private var placeholder: some View {
        Rectangle()
            .fill(Color.velvet.opacity(0.3))
            .overlay {
                Image(systemName: "book.closed")
                    .foregroundColor(.ghost)
            }
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if loadFailed {
                placeholder
            } else {
                Rectangle()
                    .fill(Color.velvet.opacity(0.3))
                    .overlay { ProgressView().tint(.paper) }
            }
        }
        .frame(width: width, height: height)
        .cornerRadius(8)
        .clipped()
        .shadow(color: .inkwell.opacity(0.1), radius: 4, x: 0, y: 2)
        .task(id: "\(urlString)-\(retryAttempt)") {
            guard !urlString.isEmpty else { return }
            var loaded = await BookCoverImageLoader.shared.load(urlString: urlString)
            if loaded == nil, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                loaded = await BookCoverImageLoader.shared.load(urlString: urlString)
            }
            if loaded == nil, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                loaded = await BookCoverImageLoader.shared.load(urlString: urlString)
            }
            if !Task.isCancelled {
                if let loaded {
                    image = loaded
                    loadFailed = false
                } else {
                    loadFailed = true
                }
            }
        }
        .onAppear {
            if loadFailed {
                loadFailed = false
                retryAttempt += 1
            }
        }
    }
}

#Preview {
    LibraryView()
        .modelContainer(for: Book.self, inMemory: true)
}
