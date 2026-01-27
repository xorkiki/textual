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
    
    // Many-to-many relationship with Tag
    @Relationship(deleteRule: .nullify, inverse: \Tag.books)
    var tags: [Tag] = []
    
    init(
        id: UUID = UUID(),
        title: String,
        author: String,
        isbn: String,
        coverURL: String = "",
        tags: [Tag] = []
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.isbn = isbn
        self.coverURL = coverURL
        self.tags = tags
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
        
        enum CodingKeys: String, CodingKey {
            case id
            case title
            case author
            case isbn
            case coverURL = "cover_url"
        }
    }
    
    /// Convert Book to Codable representation
    func toCodable() -> CodableBook {
        CodableBook(
            id: id,
            title: title,
            author: author,
            isbn: isbn,
            coverURL: coverURL
        )
    }
    
    /// Update Book from Codable representation
    func update(from codable: CodableBook) {
        self.id = codable.id
        self.title = codable.title
        self.author = codable.author
        self.isbn = codable.isbn
        self.coverURL = codable.coverURL
    }
}
