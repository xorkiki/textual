//
//  BookDetailViewModel.swift
//  textual
//
//  Created by kiki o on 1/30/26.
//

import Foundation
import Combine
import Observation
import SwiftData

@MainActor
final class BookDetailViewModel: ObservableObject {
    @Published var volume: BookCatalogService.BookItem?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let booksService: BookCatalogService

    init(booksService: BookCatalogService = .shared) {
        self.booksService = booksService
    }

    func fetchVolume(book: Book, forceRefresh: Bool = false) async {
        if isLoading { return }
        errorMessage = nil
        let cached = cachedVolume(book: book)
        volume = mergedVolume(cached, book: book)
        if !forceRefresh, cached != nil,
           let updatedAt = book.catalogMetadataUpdatedAt,
           (0.0..<TimeInterval(24 * 60 * 60)).contains(Date().timeIntervalSince(updatedAt)) {
            return
        }

        isLoading = true
        defer { isLoading = false }

        var volumeIdToUse = nonempty(cached?.id) ?? nonempty(book.googleBooksVolumeId)
        if volumeIdToUse?.hasPrefix("storygraph:") == true { volumeIdToUse = nil }
        let isbn = normalizedISBN(book.isbn)
        var resolvedByISBN = false

        // If we don't have an ID, resolve: use isbn as volume ID if it looks like one, else search by ISBN
        if volumeIdToUse == nil, !book.isbn.isEmpty {
            if let isbn {
                do {
                    resolvedByISBN = true
                    volumeIdToUse = try await booksService.searchBookId(isbn: isbn)
                } catch {
                    guard !Task.isCancelled else { return }
                    if await resolveByTitle(book: book, forceRefresh: forceRefresh) { return }
                    errorMessage = "Additional details couldn't be loaded. Your saved book is still available."
                    return
                }
            } else if book.googleBooksVolumeId?.hasPrefix("storygraph:") != true {
                volumeIdToUse = nonempty(book.isbn)
            }
        }

        guard let id = volumeIdToUse, !id.isEmpty else {
            if await resolveByTitle(book: book, forceRefresh: forceRefresh) { return }
            guard !Task.isCancelled else { return }
            if errorMessage == nil { errorMessage = "No additional details are available for this book." }
            return
        }

        do {
            let result = try await booksService.fetchVolume(id: id, forceRefresh: forceRefresh)
            guard !Task.isCancelled else { return }
            storeVolume(result, book: book)
        } catch {
            guard !Task.isCancelled else { return }
            // Fallback: if volume ID failed (e.g. 404 after Google merged editions), try resolving by ISBN
            if !resolvedByISBN, let isbn,
               let resolvedId = try? await booksService.searchBookId(isbn: isbn),
               !resolvedId.isEmpty, resolvedId != id {
                do {
                    let result = try await booksService.fetchVolume(id: resolvedId, forceRefresh: forceRefresh)
                    guard !Task.isCancelled else { return }
                    storeVolume(result, book: book)
                    return
                } catch {
                    // Keep the saved title, author, and cover below the nonblocking error.
                }
            }
            guard !Task.isCancelled else { return }
            if await resolveByTitle(book: book, forceRefresh: forceRefresh) { return }
            errorMessage = "Additional details couldn't be loaded. Your saved book is still available."
        }
    }

    private func resolveByTitle(book: Book, forceRefresh: Bool) async -> Bool {
        do {
            guard let result = try await booksService.matchedBook(title: book.title, author: book.author,
                                                                 forceRefresh: forceRefresh) else { return false }
            guard !Task.isCancelled else { return false }
            storeVolume(result, book: book)
            return true
        } catch {
            if !Task.isCancelled {
                errorMessage = "Additional details couldn't be loaded. Your saved book is still available."
            }
            return false
        }
    }

    func savedVolume(book: Book) -> BookCatalogService.BookItem {
        mergedVolume(cachedVolume(book: book), book: book)
    }

    private func cachedVolume(book: Book) -> BookCatalogService.BookItem? {
        guard let data = book.cachedCatalogMetadata,
              let cached = try? JSONDecoder().decode(BookCatalogService.BookItem.self, from: data),
              cached.volumeInfo != nil else {
            return nil
        }
        return cached
    }

    private func storeVolume(_ result: BookCatalogService.BookItem, book: Book) {
        let merged = mergedVolume(result, book: book)
        volume = merged
        do {
            book.cachedCatalogMetadata = try JSONEncoder().encode(merged)
            book.catalogMetadataUpdatedAt = Date()
            try book.modelContext?.save()
        } catch {
            errorMessage = "Details loaded, but couldn't be saved for offline reading."
        }
    }

    private func mergedVolume(_ fetched: BookCatalogService.BookItem?, book: Book) -> BookCatalogService.BookItem {
        let info = fetched?.volumeInfo
        let fetchedAuthors = info?.authors?.compactMap { nonempty($0) } ?? []
        let savedAuthors = nonempty(book.author).map { [$0] } ?? []
        let cover = nonempty(book.resolvedCoverURL)
            ?? nonempty(book.coverURL)
            ?? nonempty(info?.imageLinks?.thumbnail)
            ?? nonempty(info?.imageLinks?.smallThumbnail)

        return BookCatalogService.BookItem(
            id: fetched?.id ?? book.googleBooksVolumeId,
            volumeInfo: BookCatalogService.VolumeInfo(
                title: nonempty(book.title) ?? nonempty(info?.title),
                subtitle: info?.subtitle,
                authors: savedAuthors.isEmpty ? fetchedAuthors : savedAuthors,
                description: info?.description,
                industryIdentifiers: info?.industryIdentifiers,
                imageLinks: cover.map { .init(thumbnail: $0, smallThumbnail: nil) },
                averageRating: info?.averageRating,
                ratingsCount: info?.ratingsCount,
                categories: info?.categories?.isEmpty == false ? info?.categories : cachedVolume(book: book)?.volumeInfo?.categories,
                pageCount: info?.pageCount ?? cachedVolume(book: book)?.volumeInfo?.pageCount,
                mainCategory: info?.mainCategory ?? cachedVolume(book: book)?.volumeInfo?.mainCategory
            )
        )
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func normalizedISBN(_ value: String) -> String? {
        let isbn = value.filter { $0 != "-" && !$0.isWhitespace }.uppercased()
        let digits = "0123456789"
        if isbn.count == 13, isbn.allSatisfy({ digits.contains($0) }) { return isbn }
        if isbn.count == 10,
           isbn.dropLast().allSatisfy({ digits.contains($0) }),
           let last = isbn.last, digits.contains(last) || last == "X" {
            return isbn
        }
        return nil
    }
    
    // MARK: - Data Extractors (matches AddBookViewModel patterns)
    
    func title(from item: BookCatalogService.BookItem) -> String {
        item.volumeInfo?.title ?? "No Title"
    }
    
    func subtitle(from item: BookCatalogService.BookItem) -> String? {
        guard let sub = item.volumeInfo?.subtitle, !sub.isEmpty else { return nil }
        return sub
    }
    
    func authors(from item: BookCatalogService.BookItem) -> String {
        guard let authors = item.volumeInfo?.authors, !authors.isEmpty else {
            return "Unknown Author"
        }
        return authors.joined(separator: ", ")
    }
    
    func description(from item: BookCatalogService.BookItem) -> String? {
        BookDetailPresentation.description(item.volumeInfo?.description)
    }
    
    func coverURL(from item: BookCatalogService.BookItem) -> String {
        let urlString = item.volumeInfo?.imageLinks?.thumbnail ?? item.volumeInfo?.imageLinks?.smallThumbnail
        return BookCatalogService.secureImageURL(urlString)
    }
    
    func averageRating(from item: BookCatalogService.BookItem) -> Double? {
        item.volumeInfo?.averageRating
    }
    
    func ratingsCount(from item: BookCatalogService.BookItem) -> Int? {
        item.volumeInfo?.ratingsCount
    }
    
    func categories(from item: BookCatalogService.BookItem) -> [String] {
        BookDetailPresentation.categories(item.volumeInfo?.categories ?? [],
                                          title: item.volumeInfo?.title,
                                          description: item.volumeInfo?.description)
    }
}

// MARK: - Reusable review editor state
// Kept in this existing file so the feature needs no Xcode file registration.
@MainActor
@Observable
final class ReaderReviewEditorModel {
    let book: Book
    let store: ReaderReviewStore
    let repository: LibraryRepository?
    var content = ReaderReviewContent()
    var isBusy = false
    var message: String?
    var draft: ReaderReviewDraft?
    var didSave = false

    init(book: Book, store: ReaderReviewStore, repository: LibraryRepository?) {
        self.book = book; self.store = store; self.repository = repository
        reload()
    }
    var presentation: ReaderReviewPresentation { .init(book: book, draft: draft) }
    var canSave: Bool { content.hasAssessment && content.body.unicodeScalars.count <= 20_000 && !isBusy }
    var hasConflict: Bool { draft?.conflict != nil }
    var hasPending: Bool { draft?.pending != nil }

    func update(_ value: ReaderReviewContent) {
        content = value; didSave = false
        guard value.body.unicodeScalars.count <= 20_000 else {
            message = "Keep your review under 20,000 characters. Your last valid draft is saved."
            return
        }
        do { draft = try store.saveDraft(value, for: book); message = nil }
        catch { message = "Your draft couldn’t be saved. Keep this editor open and try again." }
    }
    func load() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await repository?.synchronize()
        do {
            try await store.loadRemote(for: book)
            reload(); message = nil
        } catch { reload(); show(error) }
    }
    func save() async {
        guard canSave else { return }
        isBusy = true; message = nil
        defer { isBusy = false }
        do {
            if book.importedReading?.status != "read", let context = book.modelContext {
                try BookReadingActions.setStatus("read", book: book, context: context, repository: repository)
            }
            draft = try store.saveDraft(content, for: book)
            await repository?.synchronize()
            if draft?.hasLoadedRemote != true { try await store.loadRemote(for: book) }
            try store.queueSubmission(for: book)
            await repository?.synchronize()
            try await store.flush()
            reload()
            if hasConflict { message = "This review changed on another device. Choose which version to keep." }
            else if hasPending { message = "Saved on this device. Your review is waiting to sync." }
            else { didSave = true }
        } catch { reload(); show(error) }
    }
    func retry() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            await repository?.synchronize()
            try await store.flush()
            reload(); message = hasPending ? "Your review is still waiting to sync." : nil
        } catch { reload(); show(error) }
    }
    func resolve(keepLocal: Bool) {
        do {
            try store.resolveConflict(for: book, keepLocal: keepLocal)
            reload()
            message = keepLocal ? "Your draft is ready. Save review to use these changes." : nil
        } catch { show(error) }
    }
    func remove() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            await repository?.synchronize()
            if draft?.hasLoadedRemote != true { try await store.loadRemote(for: book) }
            try store.queueSubmission(for: book, deleted: true)
            draft = try store.saveDraft(.init(), for: book)
            try await store.flush()
            reload()
            didSave = !hasConflict && !hasPending
        } catch { reload(); show(error) }
    }
    private func reload() {
        do {
            draft = try store.draft(for: book)
            content = presentation.editorContent
            // A brand-new review starts shared only while activity sharing is known to be on.
            // Saved and imported reviews keep their own visibility.
            if presentation.content == nil, !presentation.hasDraftChanges, store.sharesNewReviews {
                content.visibility = .public
            }
        }
        catch { show(error) }
    }
    private func show(_ error: Error) {
        if error is CancellationError { return }
        switch error {
        case ReaderReviewError.conflict:
            message = "This review changed on another device. Choose which version to keep."
        case ReaderReviewError.submissionPending:
            message = "A saved version is waiting to sync. Retry it before saving more changes."
        case ReaderReviewError.bookNotSynced, ReaderReviewError.loadRemoteFirst:
            message = "Your draft is on this device. Connect to sync this book, then save your review."
        default:
            message = hasPending
                ? "Saved on this device. We’ll retry syncing your review when you reconnect."
                : "Couldn’t connect to reviews. Your draft is on this device; try again to sync."
        }
    }
}
