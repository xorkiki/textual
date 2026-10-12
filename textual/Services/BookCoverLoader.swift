import Foundation
import Observation
import SwiftData
import UIKit

struct BookCoverIdentity: Hashable, Sendable {
    let title: String
    let author: String
    let isbn: String
    let catalogID: String?

    @MainActor init(book: Book) {
        title = book.title; author = book.author; isbn = book.isbn
        catalogID = book.volumeIdForDetailFetch
    }

    init(title: String, author: String, isbn: String = "", catalogID: String? = nil) {
        self.title = title; self.author = author; self.isbn = isbn; self.catalogID = catalogID
    }
}

enum BookCoverURL {
    /// Keep the cache identity used before default=false was added. The network
    /// URL still requests a real 404 for missing covers, without redownloading
    /// every cover already on disk under its original cover-ID URL.
    static func cacheIdentity(_ value: String) -> String {
        guard var url = URLComponents(string: value),
              url.host?.lowercased() == "covers.openlibrary.org",
              url.path.lowercased().hasPrefix("/b/id/") else { return value }
        let items = (url.queryItems ?? []).filter { $0.name != "default" }
        url.queryItems = items.isEmpty ? nil : items
        return url.string ?? value
    }

    /// A missing Open Library cover must fail rather than returning a cacheable blank image.
    static func normalized(_ value: String) -> String? {
        guard var url = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        url.scheme = "https"
        if url.host?.lowercased() == "covers.openlibrary.org" {
            var items = (url.queryItems ?? []).filter { $0.name != "default" }
            items.append(URLQueryItem(name: "default", value: "false"))
            url.queryItems = items
        }
        return url.string
    }
}

/// One bounded, cancellation-aware attempt per visible cover. Only decoded images
/// are promoted; missing images never replace the book's last working cover.
@MainActor @Observable
final class BookCoverLoader {
    private(set) var image: UIImage?
    private(set) var isLoading = false
    private var generation = UUID()
    private var loadedURL: String?
    private var loadedIdentity: BookCoverIdentity?

    func load(urls: [String], identity: BookCoverIdentity?,
              imageLoader: (String) async throws -> UIImage,
              replacements: (BookCoverIdentity) async throws -> [String],
              secondaryReplacements: ((BookCoverIdentity) async throws -> [String])? = nil) async -> String? {
        // SwiftData metadata updates can reorder or append candidate URLs. Keep
        // the displayed image when it is still one of the book's valid candidates.
        if !Task.isCancelled, image != nil, loadedIdentity == identity, let loadedURL,
           urls.compactMap(BookCoverURL.normalized).contains(loadedURL) { return loadedURL }
        let run = UUID()
        generation = run
        image = nil
        isLoading = true
        defer { if generation == run { isLoading = false } }
        var attempted = Set<String>()

        func attempt(_ candidates: [String]) async throws -> String? {
            for candidate in candidates {
                try Task.checkCancellation()
                guard generation == run else { throw CancellationError() }
                guard let url = BookCoverURL.normalized(candidate), attempted.insert(url).inserted else { continue }
                do {
                    let loaded = try await imageLoader(url)
                    try Task.checkCancellation()
                    guard generation == run else { throw CancellationError() }
                    // Open Library's historical missing-cover response is a tiny bitmap.
                    guard loaded.size.width > 8, loaded.size.height > 8 else { continue }
                    image = loaded
                    loadedURL = url
                    loadedIdentity = identity
                    return url
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                }
            }
            return nil
        }

        do {
            if let working = try await attempt(urls) { return working }
            guard let identity else { return nil }
            try Task.checkCancellation()
            let candidates = try await replacements(identity)
            if let working = try await attempt(Array(candidates.prefix(6))) { return working }
            try Task.checkCancellation()
            guard let secondaryReplacements else { return nil }
            let secondary = try await secondaryReplacements(identity)
            return try await attempt(Array(secondary.prefix(6)))
        } catch { return nil }
    }
}

extension Book {
    /// Cover recovery is a device-local cache, separate from user edits and the sync outbox.
    @MainActor func rememberCover(_ url: String) {
        guard !isRemovedFromLibrary, let normalized = BookCoverURL.normalized(url),
              normalized != BookCoverURL.normalized(coverURL), resolvedCoverURL != normalized else { return }
        let previous = resolvedCoverURL
        resolvedCoverURL = normalized
        do { try modelContext?.save() }
        catch { resolvedCoverURL = previous }
    }

    @MainActor var coverCandidates: [String] {
        let cached = cachedCatalogMetadata.flatMap {
            try? JSONDecoder().decode(BookCatalogService.BookItem.self, from: $0)
        }?.volumeInfo?.imageLinks
        return [resolvedCoverURL, coverURL, cached?.thumbnail, cached?.smallThumbnail].compactMap { $0 }
    }
}
