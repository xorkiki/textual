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
    /// Catalog ID: a Google volume ID or a namespaced openlibrary: work ID.
    /// Keep this stored property name for compatibility with existing libraries.
    var googleBooksVolumeId: String?
    /// Optional local metadata cache; additive fields preserve existing SwiftData stores.
    var cachedCatalogMetadata: Data? = nil
    var catalogMetadataUpdatedAt: Date? = nil
    /// Private import provenance and reading history. Lives in this account's store.
    var storyGraphData: Data? = nil

    var importedReading: StoryGraphReadingData? {
        storyGraphData.flatMap { try? JSONDecoder().decode(StoryGraphReadingData.self, from: $0) }
    }

    // Account-local sync outbox. `id` stays stable even when a duplicate remote
    // addition resolves to an existing library entry on another device.
    var serverEntryID: UUID? = nil
    var canonicalBookID: UUID? = nil
    var serverRevision: Int64 = 0
    var pendingOperationID: UUID? = nil
    var pendingOperationData: Data? = nil
    var syncConflictData: Data? = nil
    // PersistentModel reserves isDeleted for physical deletion from a context.
    // A synced removal must remain stored so its tombstone can reach other devices.
    var isRemovedFromLibrary: Bool = false
    
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
        self.pendingOperationID = UUID()
    }
    
    /// Volume ID to use when fetching Google Books detail (prefers googleBooksVolumeId, falls back to isbn when it looks like a volume ID)
    var volumeIdForDetailFetch: String? {
        if let id = googleBooksVolumeId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            if id.hasPrefix("storygraph:") { return nil }
            return id
        }
        let value = isbn.filter { $0 != "-" && !$0.isWhitespace }.uppercased()
        let digits = "0123456789"
        let isISBN13 = value.count == 13 && value.allSatisfy { digits.contains($0) }
        let isISBN10 = value.count == 10 && value.dropLast().allSatisfy { digits.contains($0) }
            && value.last.map { digits.contains($0) || $0 == "X" } == true
        if isISBN13 || isISBN10 { return nil }
        let legacyID = isbn.trimmingCharacters(in: .whitespacesAndNewlines)
        return legacyID.isEmpty ? nil : legacyID
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
