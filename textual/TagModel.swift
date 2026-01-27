//
//  TagModel.swift
//  textual
//
//  Created by kiki o on 1/26/26.
//

import Foundation
import SwiftData

@Model
final class Tag {
    @Attribute(.unique) var id: UUID
    var name: String
    
    // Many-to-many relationship with Book
    @Relationship(deleteRule: .nullify, inverse: \Book.tags)
    var books: [Book] = []
    
    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

// MARK: - Codable Support for Supabase Sync
extension Tag {
    /// Codable representation for Supabase sync
    struct CodableTag: Codable {
        let id: UUID
        let name: String
        
        enum CodingKeys: String, CodingKey {
            case id
            case name
        }
    }
    
    /// Convert Tag to Codable representation
    func toCodable() -> CodableTag {
        CodableTag(id: id, name: name)
    }
    
    /// Update Tag from Codable representation
    func update(from codable: CodableTag) {
        self.id = codable.id
        self.name = codable.name
    }
}
