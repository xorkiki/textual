//
//  BookDetailViewModel.swift
//  textual
//
//  Created by kiki o on 1/30/26.
//

import Foundation
import Combine
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
                    errorMessage = "Additional details couldn't be loaded. Your saved book is still available."
                    return
                }
            } else if book.googleBooksVolumeId?.hasPrefix("storygraph:") != true {
                volumeIdToUse = nonempty(book.isbn)
            }
        }

        guard let id = volumeIdToUse, !id.isEmpty else {
            errorMessage = "No additional details are available for this book."
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
            errorMessage = "Additional details couldn't be loaded. Your saved book is still available."
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
        let cover = nonempty(book.coverURL)
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
                categories: info?.categories
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
        guard let desc = item.volumeInfo?.description, !desc.isEmpty else { return nil }
        return desc
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
        item.volumeInfo?.categories ?? []
    }
}
