//
//  AddBookViewModel.swift
//  textual
//
//  Created by kiki o on 1/26/26.
//

import Foundation
import Observation

@Observable
final class AddBookViewModel {
    var searchText = ""
    var searchResults: [GoogleBooksService.BookItem] = []
    var isSearching = false
    var errorMessage: String?
    
    private let booksService = GoogleBooksService()
    
    @MainActor
    func performSearch() async {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmedQuery.isEmpty else {
            searchResults = []
            return
        }
        
        print("🔍 Performing search for: '\(trimmedQuery)'")
        isSearching = true
        errorMessage = nil
        
        do {
            let results = try await booksService.searchBooks(query: trimmedQuery)
            print("✅ Search completed: \(results.count) results")
            searchResults = results
            
            if results.isEmpty {
                print("⚠️ No results returned from API")
            }
        } catch {
            let errorMsg = "Failed to search books: \(error.localizedDescription)"
            print("❌ Search error: \(errorMsg)")
            errorMessage = errorMsg
            searchResults = []
        }
        
        isSearching = false
    }
    
    func extractTitle(from item: GoogleBooksService.BookItem) -> String {
        item.volumeInfo?.title ?? "No Title"
    }
    
    func extractISBN(from item: GoogleBooksService.BookItem) -> String {
        guard let identifiers = item.volumeInfo?.industryIdentifiers else {
            // Fallback to item ID if available
            return item.id ?? ""
        }
        
        // Prefer ISBN_13, fallback to ISBN_10
        if let isbn13 = identifiers.first(where: { $0.type == "ISBN_13" }),
           let identifier = isbn13.identifier {
            return identifier
        }
        
        if let isbn10 = identifiers.first(where: { $0.type == "ISBN_10" }),
           let identifier = isbn10.identifier {
            return identifier
        }
        
        // Final fallback to item ID
        return item.id ?? ""
    }
    
    func extractCoverURL(from item: GoogleBooksService.BookItem) -> String {
        // Prefer thumbnail, fallback to smallThumbnail
        var urlString: String?
        
        if let thumbnail = item.volumeInfo?.imageLinks?.thumbnail {
            urlString = thumbnail
        } else if let smallThumbnail = item.volumeInfo?.imageLinks?.smallThumbnail {
            urlString = smallThumbnail
        }
        
        guard var url = urlString else {
            return ""
        }
        
        // Convert HTTP to HTTPS
        if url.hasPrefix("http://") {
            url = url.replacingOccurrences(of: "http://", with: "https://")
        }
        
        return url
    }
    
    func extractAuthor(from item: GoogleBooksService.BookItem) -> String {
        guard let authors = item.volumeInfo?.authors, !authors.isEmpty else {
            return "Unknown Author"
        }
        return authors.joined(separator: ", ")
    }
}
