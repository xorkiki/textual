//
//  BookDetailViewModel.swift
//  textual
//
//  Created by kiki o on 1/30/26.
//

import Foundation
import Combine

@MainActor
final class BookDetailViewModel: ObservableObject {
    @Published var volume: GoogleBooksService.BookItem?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let booksService = GoogleBooksService()

    func fetchVolume(book: Book) async {
        if isLoading { return }
        isLoading = true
        errorMessage = nil
        volume = nil

        var volumeIdToUse = book.googleBooksVolumeId

        // If we don't have an ID, resolve: use isbn as volume ID if it looks like one, else search by ISBN
        if volumeIdToUse == nil || volumeIdToUse?.isEmpty == true, !book.isbn.isEmpty {
            let digitsOnly = book.isbn.replacingOccurrences(of: "-", with: "").filter { $0.isNumber }
            let looksLikeIsbn = digitsOnly.count == 10 || digitsOnly.count == 13
            if looksLikeIsbn {
                do {
                    volumeIdToUse = try await booksService.searchBookId(isbn: book.isbn)
                } catch {
                    print("Failed to resolve ISBN to ID: \(error)")
                }
            } else {
                volumeIdToUse = book.isbn
            }
        }

        guard let id = volumeIdToUse, !id.isEmpty else {
            errorMessage = "Could not find book details."
            isLoading = false
            return
        }

        do {
            let result = try await booksService.fetchVolume(id: id)
            volume = result
            isLoading = false
        } catch {
            // Fallback: if volume ID failed (e.g. 404 after Google merged editions), try resolving by ISBN
            let digitsOnly = book.isbn.replacingOccurrences(of: "-", with: "").filter { $0.isNumber }
            let hasValidIsbn = digitsOnly.count == 10 || digitsOnly.count == 13
            if hasValidIsbn, let resolvedId = try? await booksService.searchBookId(isbn: book.isbn), !resolvedId.isEmpty {
                do {
                    let result = try await booksService.fetchVolume(id: resolvedId)
                    volume = result
                    errorMessage = nil
                } catch {
                    errorMessage = "Failed to load book details"
                    volume = nil
                }
            } else {
                errorMessage = "Failed to load book details"
                volume = nil
            }
            isLoading = false
        }
    }
    
    // MARK: - Data Extractors (matches AddBookViewModel patterns)
    
    func title(from item: GoogleBooksService.BookItem) -> String {
        item.volumeInfo?.title ?? "No Title"
    }
    
    func subtitle(from item: GoogleBooksService.BookItem) -> String? {
        guard let sub = item.volumeInfo?.subtitle, !sub.isEmpty else { return nil }
        return sub
    }
    
    func authors(from item: GoogleBooksService.BookItem) -> String {
        guard let authors = item.volumeInfo?.authors, !authors.isEmpty else {
            return "Unknown Author"
        }
        return authors.joined(separator: ", ")
    }
    
    func description(from item: GoogleBooksService.BookItem) -> String? {
        guard let desc = item.volumeInfo?.description, !desc.isEmpty else { return nil }
        return desc
    }
    
    func coverURL(from item: GoogleBooksService.BookItem) -> String {
        let urlString = item.volumeInfo?.imageLinks?.thumbnail ?? item.volumeInfo?.imageLinks?.smallThumbnail
        return GoogleBooksService.secureImageURL(urlString)
    }
    
    func averageRating(from item: GoogleBooksService.BookItem) -> Double? {
        item.volumeInfo?.averageRating
    }
    
    func ratingsCount(from item: GoogleBooksService.BookItem) -> Int? {
        item.volumeInfo?.ratingsCount
    }
    
    func categories(from item: GoogleBooksService.BookItem) -> [String] {
        item.volumeInfo?.categories ?? []
    }
}
