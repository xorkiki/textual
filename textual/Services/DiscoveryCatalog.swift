import Foundation
import SwiftData

/// Server collections behind Discover, plus the device-computed For You list.
enum DiscoveryCollection: String, CaseIterable, Sendable {
    case trending, newReleases = "new_releases", explore, forYou = "for_you", forYouAuthors = "for_you_authors"

    /// Collections fetched from `textual_read_discovery`.
    static let remote: [DiscoveryCollection] = [.trending, .newReleases, .explore]

    /// Charts change daily; catalog pools change slowly. Pull-to-refresh bypasses this.
    var freshness: TimeInterval {
        switch self {
        case .trending: return 3 * 3600
        case .newReleases, .explore: return 12 * 3600
        case .forYou, .forYouAuthors: return 7 * 86_400
        }
    }
}

/// One cached discovery row. Catalog metadata only; never a reader's private data,
/// except For You rows, which live in this account's private store.
@Model
final class DiscoveryCacheEntry {
    /// "<collection>|<catalog ID>"
    @Attribute(.unique) var key: String
    var collection: String
    var position: Int
    /// Same form as `Book.googleBooksVolumeId`: a Google volume ID or "openlibrary:OL…W".
    var catalogID: String
    var title: String
    var author: String
    var isbns: [String] = []
    var coverURL: String
    /// Height ÷ width, measured by the server (or a stable fallback) so cells never jump.
    var coverAspect: Double
    var firstPublishedYear: Int?
    var subjects: [String] = []
    var facet: String?
    var sources: [String] = []
    var popularity: Int = 0
    var expiresAt: Date?
    /// Structured For You reasons, kept for future use and never shown in the grid.
    var reasons: [String] = []

    init(collection: DiscoveryCollection, position: Int, item: DiscoverItem, reasons: [String] = []) {
        key = Self.key(collection, item.catalogID)
        self.collection = collection.rawValue
        catalogID = item.catalogID
        self.position = position
        title = item.title
        author = item.author
        coverURL = item.coverURL
        coverAspect = item.aspect
        update(position: position, item: item, reasons: reasons)
    }

    func update(position: Int, item: DiscoverItem, reasons: [String]) {
        self.position = position
        title = item.title
        author = item.author
        isbns = item.isbns
        coverURL = item.coverURL
        coverAspect = item.aspect
        firstPublishedYear = item.firstPublishedYear
        subjects = item.subjects
        facet = item.facet
        sources = item.sources
        popularity = item.popularity
        expiresAt = item.expiresAt
        self.reasons = reasons
    }

    static func key(_ collection: DiscoveryCollection, _ catalogID: String) -> String {
        "\(collection.rawValue)|\(catalogID)"
    }

    var item: DiscoverItem {
        DiscoverItem(catalogID: catalogID, title: title, author: author, isbns: isbns, coverURL: coverURL,
                     aspect: coverAspect, firstPublishedYear: firstPublishedYear, subjects: subjects,
                     facet: facet, sources: sources, popularity: popularity, expiresAt: expiresAt)
    }
}

/// Refresh bookkeeping per collection: last success, server time, and failure backoff.
@Model
final class DiscoveryCollectionState {
    @Attribute(.unique) var collection: String
    var fetchedAt: Date?
    var serverRefreshedAt: Date?
    var attribution: [String] = []
    var lastFailureAt: Date?
    var failureCount: Int = 0
    /// For You: stable fingerprint of the taste signals and pools last ranked.
    var inputSignature: String?

    init(collection: DiscoveryCollection) { self.collection = collection.rawValue }
}

/// Immutable value used by views and ranking; SwiftData models stay on the main actor.
struct DiscoverItem: Identifiable, Hashable, Sendable {
    let catalogID: String
    let title: String
    let author: String
    let isbns: [String]
    let coverURL: String
    let aspect: Double
    let firstPublishedYear: Int?
    let subjects: [String]
    let facet: String?
    let sources: [String]
    let popularity: Int
    let expiresAt: Date?
    var id: String { catalogID }

    /// Covers outside the server's measurements use a book-like ratio, frozen at first layout.
    static let fallbackAspect = 1.5

    func isVisible(at date: Date) -> Bool { expiresAt.map { $0 > date } ?? true }

    func withFacet(_ facet: String) -> DiscoverItem {
        DiscoverItem(catalogID: catalogID, title: title, author: author, isbns: isbns, coverURL: coverURL,
                     aspect: aspect, firstPublishedYear: firstPublishedYear, subjects: subjects, facet: facet,
                     sources: sources, popularity: popularity, expiresAt: expiresAt)
    }

    /// A detached catalog book for details and saving, like a shared favorite.
    func catalogBook() -> Book {
        Book(title: title, author: author, isbn: isbns.first ?? catalogID,
             coverURL: coverURL, googleBooksVolumeId: catalogID)
    }
}

// MARK: - Wire format

/// Response of `textual_read_discovery`.
struct DiscoveryPage: Decodable, Sendable {
    let collection: String
    let refreshedAt: String?
    let total: Int
    let attribution: [String]
    let books: [Row]

    struct Row: Decodable, Sendable {
        let provider: String
        let providerID: String
        let title: String
        let author: String
        let isbns: [String]
        let coverURL: String
        let coverWidth: Int
        let coverHeight: Int
        let firstPublishedYear: Int?
        let subjects: [String]
        let popularity: Int
        let position: Int
        let sources: [String]
        let facet: String?
        let expiresAt: String?

        enum CodingKeys: String, CodingKey {
            case provider, title, author, isbns, subjects, popularity, position, sources, facet
            case providerID = "provider_id", coverURL = "cover_url", coverWidth = "cover_width"
            case coverHeight = "cover_height", firstPublishedYear = "first_published_year"
            case expiresAt = "expires_at"
        }

        /// Matches the catalog-ID convention used by search, saving, and sync.
        var catalogID: String? {
            switch provider {
            case "openlibrary":
                return providerID.range(of: "^OL[0-9]+W$", options: .regularExpression) == nil ? nil : "openlibrary:\(providerID)"
            case "google":
                return providerID.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) == nil ? nil : providerID
            default: return nil
            }
        }

        var item: DiscoverItem? {
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let catalogID, !title.isEmpty, coverWidth > 0, coverHeight > 0,
                  BookCoverURL.normalized(coverURL) != nil else { return nil }
            return DiscoverItem(catalogID: catalogID, title: title, author: author, isbns: isbns,
                                coverURL: coverURL, aspect: Double(coverHeight) / Double(coverWidth),
                                firstPublishedYear: firstPublishedYear, subjects: subjects, facet: facet,
                                sources: sources, popularity: popularity,
                                expiresAt: expiresAt.flatMap(DiscoveryDate.parse))
        }
    }

    enum CodingKeys: String, CodingKey {
        case collection, total, attribution, books
        case refreshedAt = "refreshed_at"
    }
}

/// PostgreSQL timestamps arrive with or without fractional seconds.
enum DiscoveryDate {
    static func parse(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

// MARK: - Identity

/// Matching for "is this discovered book already in my archive?". Catalog ID and
/// ISBN are authoritative; exact main title + author identity is the cautious fallback.
enum DiscoveryIdentity {
    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "").replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "&", with: " and ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Main title without trailing series markers or subtitles.
    static func titleKey(_ title: String) -> String {
        var main = title.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\[[^\]]*\]\s*$"#, with: "", options: .regularExpression)
        if let range = main.range(of: #":\s| - "#, options: .regularExpression) { main = String(main[..<range.lowerBound]) }
        let folded = fold(main)
        for article in ["the ", "a ", "an "] where folded.hasPrefix(article) { return String(folded.dropFirst(article.count)) }
        return folded
    }

    /// "J.R.R. Tolkien" equals "J. R. R. Tolkien"; a different given name does not.
    static func authorKey(_ author: String) -> String {
        var words: [String] = []
        var initials = ""
        for token in fold(author).split(separator: " ") {
            if token.count == 1 { initials += token }
            else {
                if !initials.isEmpty { words.append(initials); initials = "" }
                words.append(String(token))
            }
        }
        if !initials.isEmpty { words.append(initials) }
        return words.joined(separator: " ")
    }

    static func primaryAuthorKey(_ author: String) -> String {
        authorKey(author.components(separatedBy: CharacterSet(charactersIn: ",&")).first ?? author)
    }

    static func workKey(title: String, author: String) -> String? {
        let title = titleKey(title), author = primaryAuthorKey(author)
        return title.isEmpty || author.isEmpty ? nil : "\(title)|\(author)"
    }
}

/// Resolves discovered books to the reader's existing archive records.
@MainActor
struct DiscoveryArchiveIndex {
    private var byCatalogID: [String: Book] = [:]
    private var byISBN: [String: Book] = [:]
    private var byWork: [String: Book] = [:]
    private var ambiguousWorks: Set<String> = []

    init(books: [Book] = []) {
        for book in books where !book.isRemovedFromLibrary {
            if let id = book.googleBooksVolumeId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
                byCatalogID[id] = book
            }
            if let cached = book.cachedCatalogMetadata.flatMap({ try? JSONDecoder().decode(BookCatalogService.BookItem.self, from: $0) }),
               let id = cached.id, byCatalogID[id] == nil {
                byCatalogID[id] = book
            }
            if let isbn = StoryGraphImporter.normalizedISBN(book.isbn) { byISBN[isbn] = book }
            if let key = DiscoveryIdentity.workKey(title: book.title, author: book.author) {
                // Two archive books with one title/author key are left to stronger identifiers.
                if byWork[key] != nil { ambiguousWorks.insert(key) } else { byWork[key] = book }
            }
        }
        for key in ambiguousWorks { byWork.removeValue(forKey: key) }
    }

    func book(for item: DiscoverItem) -> Book? {
        if let book = byCatalogID[item.catalogID] { return book }
        for isbn in item.isbns {
            if let normalized = StoryGraphImporter.normalizedISBN(isbn), let book = byISBN[normalized] { return book }
        }
        return DiscoveryIdentity.workKey(title: item.title, author: item.author).flatMap { byWork[$0] }
    }

    func contains(_ item: DiscoverItem) -> Bool { book(for: item) != nil }
}
