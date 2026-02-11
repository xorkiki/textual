//
//  BookDetailViewModel.swift
//  textual
//
//  Created by kiki o on 1/30/26.
//

import Foundation
import Combine

// #region agent log
private func _dbg(_ msg: String, loc: String, hyp: String, data: [String: Any] = [:]) {
    let payload: [String: Any] = ["timestamp": Int(Date().timeIntervalSince1970 * 1000), "sessionId": "debug-session", "runId": "run1", "location": loc, "message": msg, "data": data, "hypothesisId": hyp]
    guard let json = try? JSONSerialization.data(withJSONObject: payload), let line = String(data: json, encoding: .utf8), let bytes = (line + "\n").data(using: .utf8) else { return }
    let path = "/Users/kiki/Desktop/textual/textual/.cursor/debug.log"
    if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
    if let fh = try? FileHandle(forUpdating: URL(fileURLWithPath: path)) { fh.seekToEndOfFile(); fh.write(bytes); try? fh.close() }
}
// #endregion

@MainActor
final class BookDetailViewModel: ObservableObject {
    @Published var volume: GoogleBooksService.BookItem?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let booksService = GoogleBooksService()

    func fetchVolume(book: Book) async {
        // #region agent log
        if isLoading { _dbg("fetchVolume skipped already loading", loc: "BookDetailViewModel.fetchVolume", hyp: "C", data: ["bookId": book.id.uuidString]); return }
        _dbg("fetchVolume started", loc: "BookDetailViewModel.fetchVolume", hyp: "C", data: ["bookId": book.id.uuidString, "hasGoogleId": book.googleBooksVolumeId != nil])
        // #endregion
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
            // #region agent log
            _dbg("fetchVolume no id", loc: "BookDetailViewModel.fetchVolume", hyp: "F", data: ["bookId": book.id.uuidString])
            // #endregion
            errorMessage = "Could not find book details."
            isLoading = false
            return
        }

        do {
            let result = try await booksService.fetchVolume(id: id)
            // #region agent log
            _dbg("about to set volume", loc: "BookDetailViewModel.fetchVolume", hyp: "B", data: ["volumeId": id])
            // #endregion
            volume = result
            isLoading = false
            // #region agent log
            _dbg("volume set", loc: "BookDetailViewModel.fetchVolume", hyp: "A,E", data: ["hasVolume": volume != nil])
            // #endregion
        } catch {
            // #region agent log
            _dbg("fetchVolume catch", loc: "BookDetailViewModel.fetchVolume", hyp: "F", data: ["bookId": book.id.uuidString, "error": String(describing: error)])
            // #endregion
            errorMessage = "Failed to load book details"
            volume = nil
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
        var urlString: String?
        if let thumbnail = item.volumeInfo?.imageLinks?.thumbnail {
            urlString = thumbnail
        } else if let smallThumbnail = item.volumeInfo?.imageLinks?.smallThumbnail {
            urlString = smallThumbnail
        }
        guard var url = urlString else { return "" }
        if url.hasPrefix("http://") {
            url = url.replacingOccurrences(of: "http://", with: "https://")
        }
        return url
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
