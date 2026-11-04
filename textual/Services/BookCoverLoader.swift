import Foundation
import Observation
import SwiftData
import UIKit

@MainActor
private final class CoverResolutionBatch {
    struct Pending {
        let book: Book
        let original: String?
        var resolved: String
    }

    let context: ModelContext
    var pending: [UUID: Pending] = [:]
    var task: Task<Void, Never>?

    init(context: ModelContext) { self.context = context }
}

/// Resolving covers is cache maintenance, so coalesce writes per SwiftData
/// context instead of saving the entire library once for every visible image.
@MainActor
private enum CoverResolutionWriter {
    private static var batches: [ObjectIdentifier: CoverResolutionBatch] = [:]
    private static let delay: Duration = .milliseconds(350)

    static func enqueue(_ book: Book, original: String?, url: String) {
        guard !book.isRemovedFromLibrary, let context = book.modelContext else { return }
        let key = ObjectIdentifier(context)
        let batch = batches[key] ?? CoverResolutionBatch(context: context)
        batches[key] = batch
        let firstValue = batch.pending[book.id].map { $0.original } ?? original
        batch.pending[book.id] = .init(book: book, original: firstValue, resolved: url)
        batch.task?.cancel()
        batch.task = Task { @MainActor in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            flush(batch, key: key)
        }
    }

    private static func flush(_ batch: CoverResolutionBatch, key: ObjectIdentifier) {
        guard batches[key] === batch else { return }
        batch.task = nil
        var changed: [CoverResolutionBatch.Pending] = []
        for pending in batch.pending.values {
            let book = pending.book
            guard !book.isRemovedFromLibrary, book.modelContext === batch.context,
                  book.resolvedCoverURL == pending.original else { continue }
            book.resolvedCoverURL = pending.resolved
            changed.append(pending)
        }
        batch.pending.removeAll(keepingCapacity: true)
        guard !changed.isEmpty else {
            batches.removeValue(forKey: key)
            return
        }
        do {
            try batch.context.save()
        } catch {
            // Restore only the cache fields this batch changed. Do not roll back
            // unrelated user edits that may share this context.
            for pending in changed where pending.book.resolvedCoverURL == pending.resolved {
                pending.book.resolvedCoverURL = pending.original
            }
        }
        if batch.pending.isEmpty { batches.removeValue(forKey: key) }
    }
}

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

    func load(urls: [String], identity: BookCoverIdentity?,
              cachedImageLoader: ((String) async throws -> UIImage)? = nil,
              imageLoader: (String) async throws -> UIImage,
              replacements: (BookCoverIdentity) async throws -> [String],
              secondaryReplacements: ((BookCoverIdentity) async throws -> [String])? = nil) async -> String? {
        // SwiftData metadata updates can reorder or append candidate URLs. Keep
        // the displayed image when it is still one of the book's valid candidates.
        guard !Task.isCancelled else { return nil }
        // An unchanged image URL remains valid when catalog metadata fills in.
        if image != nil, let loadedURL,
           urls.compactMap(BookCoverURL.normalized).contains(loadedURL) { return loadedURL }
        let run = UUID()
        generation = run
        image = nil
        isLoading = true
        defer { if generation == run { isLoading = false } }
        var attempted = Set<String>()
        var checkedCache = Set<String>()

        func attempt(_ candidates: [String], using readImage: (String) async throws -> UIImage,
                     cacheOnly: Bool = false) async throws -> String? {
            for candidate in candidates {
                try Task.checkCancellation()
                guard generation == run else { throw CancellationError() }
                guard let url = BookCoverURL.normalized(candidate) else { continue }
                let isNew = cacheOnly ? checkedCache.insert(url).inserted : attempted.insert(url).inserted
                guard isNew else { continue }
                do {
                    let loaded = try await readImage(url)
                    try Task.checkCancellation()
                    guard generation == run else { throw CancellationError() }
                    // Open Library's historical missing-cover response is a tiny bitmap.
                    guard loaded.size.width > 8, loaded.size.height > 8 else { continue }
                    image = loaded
                    loadedURL = url
                    return url
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                }
            }
            return nil
        }

        func loadCandidates(_ candidates: [String]) async throws -> String? {
            // Check every known URL on disk before any one URL can wait on the network.
            // Nuke performs the disk read and image decoding off the main thread.
            if let cachedImageLoader,
               let working = try await attempt(candidates, using: cachedImageLoader, cacheOnly: true) {
                return working
            }
            return try await attempt(candidates, using: imageLoader)
        }

        do {
            if let working = try await loadCandidates(urls) { return working }
            guard let identity else { return nil }
            try Task.checkCancellation()
            let candidates = try await replacements(identity)
            if let working = try await loadCandidates(Array(candidates.prefix(6))) { return working }
            try Task.checkCancellation()
            guard let secondaryReplacements else { return nil }
            let secondary = try await secondaryReplacements(identity)
            return try await loadCandidates(Array(secondary.prefix(6)))
        } catch { return nil }
    }
}

extension Book {
    /// Cover recovery is a device-local cache, separate from user edits and the sync outbox.
    @MainActor func rememberCover(_ url: String) {
        guard !isRemovedFromLibrary, let normalized = BookCoverURL.normalized(url),
              normalized != BookCoverURL.normalized(coverURL), resolvedCoverURL != normalized else { return }
        CoverResolutionWriter.enqueue(self, original: resolvedCoverURL, url: normalized)
    }
}
