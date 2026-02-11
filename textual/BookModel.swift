//
//  BookModel.swift
//  textual
//
//  Created by kiki o on 1/26/26.
//

import Foundation
import SwiftData

@Model
final class Book {
    @Attribute(.unique) var id: UUID
    var title: String
    var author: String
    var isbn: String
    var coverURL: String
    /// Google Books API volume ID for fetching full details via volumes/{id}
    var googleBooksVolumeId: String?
    
    // Many-to-many relationship with Tag
    @Relationship(deleteRule: .nullify, inverse: \Tag.books)
    var tags: [Tag] = []
    
    init(
        id: UUID = UUID(),
        title: String,
        author: String,
        isbn: String,
        coverURL: String = "",
        googleBooksVolumeId: String? = nil,
        tags: [Tag] = []
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.isbn = isbn
        self.coverURL = coverURL
        self.googleBooksVolumeId = googleBooksVolumeId
        self.tags = tags
    }
    
    /// Volume ID to use when fetching Google Books detail (prefers googleBooksVolumeId, falls back to isbn when it looks like a volume ID)
    var volumeIdForDetailFetch: String? {
        if let vid = googleBooksVolumeId, !vid.isEmpty { return vid }
        // ISBNs are typically 10 or 13 digits (with possible hyphens); volume IDs are alphanumeric
        let digitsOnly = isbn.replacingOccurrences(of: "-", with: "").filter { $0.isNumber }
        if digitsOnly.count == 10 || digitsOnly.count == 13 { return nil }
        return isbn.isEmpty ? nil : isbn
    }
}

// MARK: - Codable Support for Supabase Sync
extension Book {
    /// Codable representation for Supabase sync
    struct CodableBook: Codable {
        let id: UUID
        let title: String
        let author: String
        let isbn: String
        let coverURL: String
        let googleBooksVolumeId: String?
        
        enum CodingKeys: String, CodingKey {
            case id
            case title
            case author
            case isbn
            case coverURL = "cover_url"
            case googleBooksVolumeId = "google_books_volume_id"
        }
    }
    
    /// Convert Book to Codable representation
    func toCodable() -> CodableBook {
        CodableBook(
            id: id,
            title: title,
            author: author,
            isbn: isbn,
            coverURL: coverURL,
            googleBooksVolumeId: googleBooksVolumeId
        )
    }
    
    /// Update Book from Codable representation
    func update(from codable: CodableBook) {
        self.id = codable.id
        self.title = codable.title
        self.author = codable.author
        self.isbn = codable.isbn
        self.coverURL = codable.coverURL
        self.googleBooksVolumeId = codable.googleBooksVolumeId
    }
}
