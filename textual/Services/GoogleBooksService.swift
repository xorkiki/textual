//
//  GoogleBooksService.swift
//  textual
//
//  Created by kiki o on 1/26/26.
//

import Foundation

actor GoogleBooksService {
    private let baseURL = "https://www.googleapis.com/books/v1/volumes"
    
    struct SearchResult: Codable {
        let items: [BookItem]?
    }
    
    /// Response from volumes/{id} endpoint - single volume
    struct VolumeResponse: Codable {
        let id: String?
        let volumeInfo: VolumeInfo?
    }
    
    struct BookItem: Codable {
        let id: String?
        let volumeInfo: VolumeInfo?
        
        enum CodingKeys: String, CodingKey {
            case id
            case volumeInfo
        }
    }
    
    struct VolumeInfo: Codable {
        let title: String?
        let subtitle: String?
        let authors: [String]?
        let description: String?
        let industryIdentifiers: [IndustryIdentifier]?
        let imageLinks: ImageLinks?
        let averageRating: Double?
        let ratingsCount: Int?
        let categories: [String]?
        
        enum CodingKeys: String, CodingKey {
            case title
            case subtitle
            case authors
            case description
            case industryIdentifiers
            case imageLinks
            case averageRating
            case ratingsCount
            case categories
        }
        
        struct IndustryIdentifier: Codable {
            let type: String?
            let identifier: String?
            
            enum CodingKeys: String, CodingKey {
                case type
                case identifier
            }
        }
        
        struct ImageLinks: Codable {
            let thumbnail: String?
            let smallThumbnail: String?
            
            enum CodingKeys: String, CodingKey {
                case thumbnail
                case smallThumbnail
            }
        }
    }
    
    /// Fetches full volume data using volumes/{id} endpoint.
    /// Throws `ServiceError.notFound` on 404 so callers can fall back to ISBN search.
    func fetchVolume(id: String) async throws -> BookItem {
        let urlString = "\(baseURL)/\(id)"
        guard let url = URL(string: urlString) else {
            throw ServiceError.invalidURL
        }
        
        let (data, response) = try await URLSession.shared.data(from: url)
        
        if let httpResponse = response as? HTTPURLResponse {
            guard httpResponse.statusCode == 200 else {
                if let errorString = String(data: data, encoding: .utf8) {
                    print("❌ Volume API Error (\(httpResponse.statusCode)): \(errorString)")
                }
                if httpResponse.statusCode == 404 {
                    throw ServiceError.notFound
                }
                throw ServiceError.noResults
            }
        }
        
        let volumeResponse = try JSONDecoder().decode(VolumeResponse.self, from: data)
        return BookItem(
            id: volumeResponse.id ?? id,
            volumeInfo: volumeResponse.volumeInfo
        )
    }
    
    /// Searches for a book by ISBN to resolve the Volume ID
    func searchBookId(isbn: String) async throws -> String? {
        let query = "isbn:\(isbn)"
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        let urlString = "\(baseURL)?q=\(encodedQuery)&maxResults=1&printType=books"
        guard let url = URL(string: urlString) else { throw ServiceError.invalidURL }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw ServiceError.noResults
        }
        struct SearchIdResponse: Decodable {
            struct Item: Decodable { let id: String }
            let items: [Item]?
        }
        let decoded = try JSONDecoder().decode(SearchIdResponse.self, from: data)
        return decoded.items?.first?.id
    }
    
    /// Search by title (uses intitle: for better relevance). Supports pagination.
    /// - Parameters:
    ///   - query: Search text (e.g. book title); will be prefixed with intitle:
    ///   - startIndex: Offset for pagination (0 = first page, 40 = second page when using maxResults=40)
    /// - Returns: Up to 40 book items (books only, excludes magazines/periodicals)
    func searchBooks(query: String, startIndex: Int = 0) async throws -> [BookItem] {
        let titleQuery = "intitle:\(query)"
        guard let encodedQuery = titleQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw ServiceError.invalidQuery
        }
        let maxResults = 40
        let urlString = "\(baseURL)?q=\(encodedQuery)&maxResults=\(maxResults)&startIndex=\(startIndex)&printType=books"
        print("🔍 Searching Google Books API: \(urlString)")
        
        guard let url = URL(string: urlString) else {
            throw ServiceError.invalidURL
        }
        
        let (data, response) = try await URLSession.shared.data(from: url)
        
        // Log response status
        if let httpResponse = response as? HTTPURLResponse {
            print("📡 API Response Status: \(httpResponse.statusCode)")
            if httpResponse.statusCode != 200 {
                if let errorString = String(data: data, encoding: .utf8) {
                    print("❌ API Error Response: \(errorString)")
                }
            }
        }
        
        // Detailed error handling for JSON decoding
        do {
            let result = try JSONDecoder().decode(SearchResult.self, from: data)
            let items = result.items ?? []
            
            print("✅ Decoded \(items.count) items from API")
            
            // Filter out invalid items (must have at least an ID or title)
            let validItems = items.filter { item in
                (item.id != nil && !item.id!.isEmpty) ||
                (item.volumeInfo?.title != nil && !item.volumeInfo!.title!.isEmpty)
            }
            
            print("✅ Filtered to \(validItems.count) valid items")
            
            // Log first item for debugging
            if let firstItem = validItems.first {
                print("📚 First item: ID=\(firstItem.id ?? "nil"), Title=\(firstItem.volumeInfo?.title ?? "nil")")
            }
            
            return validItems
        } catch let decodingError as DecodingError {
            // Print detailed decoding error information
            switch decodingError {
            case .keyNotFound(let key, let context):
                print("❌ JSON Decoding Error - Key not found: '\(key.stringValue)' at path: \(context.codingPath.map { $0.stringValue }.joined(separator: "."))")
                print("   Context: \(context.debugDescription)")
            case .typeMismatch(let type, let context):
                print("❌ JSON Decoding Error - Type mismatch: expected \(type) at path: \(context.codingPath.map { $0.stringValue }.joined(separator: "."))")
                print("   Context: \(context.debugDescription)")
            case .valueNotFound(let type, let context):
                print("❌ JSON Decoding Error - Value not found: expected \(type) at path: \(context.codingPath.map { $0.stringValue }.joined(separator: "."))")
                print("   Context: \(context.debugDescription)")
            case .dataCorrupted(let context):
                print("❌ JSON Decoding Error - Data corrupted at path: \(context.codingPath.map { $0.stringValue }.joined(separator: "."))")
                print("   Context: \(context.debugDescription)")
            @unknown default:
                print("❌ JSON Decoding Error - Unknown error: \(decodingError)")
            }
            
            // Try to print a sample of the raw JSON for debugging
            if let jsonString = String(data: data, encoding: .utf8) {
                print("📄 Raw JSON sample (first 500 chars):")
                print(String(jsonString.prefix(500)))
            }
            
            throw ServiceError.decodingFailed(decodingError)
        } catch {
            print("❌ Unexpected error during JSON decoding: \(error)")
            throw ServiceError.decodingFailed(error)
        }
    }
    
    /// Returns a secure (HTTPS) URL string for use with Nuke/ATS. Google often returns http.
    static func secureImageURL(_ urlString: String?) -> String {
        guard var url = urlString, !url.isEmpty else { return "" }
        if url.hasPrefix("http://") {
            url = url.replacingOccurrences(of: "http://", with: "https://")
        }
        return url
    }

    enum ServiceError: Error {
        case invalidQuery
        case invalidURL
        case noResults
        case notFound
        case decodingFailed(Error)
    }
}
