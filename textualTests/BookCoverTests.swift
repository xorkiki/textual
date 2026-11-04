import Foundation
import SwiftData
import Testing
import UIKit
import Nuke
@testable import textual

@Suite @MainActor
struct BookCoverTests {
    private let identity = BookCoverIdentity(title: "A Wizard of Earthsea", author: "Ursula K. Le Guin", isbn: "9780547773742")
    private let broken = "https://covers.openlibrary.org/b/isbn/9780547773742-M.jpg?default=false"
    private let replacement = "https://covers.openlibrary.org/b/id/12345-M.jpg?default=false"

    private func bitmap(_ size: CGFloat = 40) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }
    }

    @Test func cachedCoverIsAvailableSynchronouslyWithEquivalentURLs() throws {
        let pipeline = ImagePipeline { $0.imageCache = ImageCache() }
        let original = "http://covers.openlibrary.org/b/id/7654321-M.jpg"
        let normalized = "https://covers.openlibrary.org/b/id/7654321-M.jpg?default=false"
        let request = try #require(BookCoverImage.imageRequest(original, width: 110, height: 170))
        let decoded = bitmap()
        pipeline.cache.storeCachedImage(ImageContainer(image: decoded), for: request, caches: [.memory])
        // A recreated view can render this very same decoded bitmap on its first
        // frame, without awaiting disk, decoding, a task, or the network.
        let cached = BookCoverImage.cachedImage(urls: ["invalid", normalized], width: 110, height: 170, pipeline: pipeline)
        #expect(cached === decoded)
        #expect(BookCoverImage.cachedImage(urls: [normalized], width: 220, height: 340, pipeline: pipeline) == nil)
    }

    @Test func memoryCacheDoesNotDisplayKnownMissingCoverBitmaps() throws {
        let pipeline = ImagePipeline { $0.imageCache = ImageCache() }
        let request = try #require(BookCoverImage.imageRequest(broken, width: 110, height: 170))
        pipeline.cache.storeCachedImage(ImageContainer(image: bitmap(1)), for: request, caches: [.memory])
        #expect(BookCoverImage.cachedImage(urls: [broken], width: 110, height: 170, pipeline: pipeline) == nil)
    }

    @Test func aWorkingFirstFallbackNeverWaitsForTheSecondProvider() async {
        let loader = BookCoverLoader()
        let result = await loader.load(urls: [], identity: identity, imageLoader: { _ in bitmap() },
            replacements: { _ in [replacement] }, secondaryReplacements: { _ in
                Issue.record("A working first-provider cover must appear without querying the second provider")
                return []
            })
        #expect(result == replacement)
    }

    @Test func failedFirstProviderCoverCanUseTheSecondProvider() async {
        let loader = BookCoverLoader()
        let result = await loader.load(urls: [], identity: identity, imageLoader: { url in
            if url == broken { throw URLError(.fileDoesNotExist) }
            return bitmap()
        }, replacements: { _ in [broken] }, secondaryReplacements: { _ in [replacement] })
        #expect(result == replacement)
    }

    @Test func metadataUpdatesKeepTheAlreadyLoadedImage() async {
        let loader = BookCoverLoader()
        var imageRequests = 0
        _ = await loader.load(urls: [], identity: identity, imageLoader: { _ in
            imageRequests += 1
            return bitmap()
        }, replacements: { _ in [replacement] })
        let previous = loader.image
        let result = await loader.load(urls: [replacement, broken], identity: identity, imageLoader: { _ in
            imageRequests += 1
            return bitmap()
        }, replacements: { _ in [] })
        #expect(result == replacement)
        #expect(imageRequests == 1)
        #expect(loader.image === previous)
    }

    @Test func missingCoverFlagPreservesTheExistingDiskCacheEntry() throws {
        let original = "https://covers.openlibrary.org/b/id/12345-M.jpg"
        let updated = try #require(BookCoverURL.normalized(original))
        let pipeline = ImagePipeline()
        let oldRequest = ImageRequest(url: try #require(URL(string: original)))
        let newRequest = ImageRequest(url: try #require(URL(string: updated)), userInfo: [.imageIdKey: BookCoverURL.cacheIdentity(updated)])
        #expect(pipeline.cache.makeDataCacheKey(for: oldRequest) == pipeline.cache.makeDataCacheKey(for: newRequest))
        #expect(newRequest.url?.query == "default=false")
    }

    @Test func cachedAlternativeDoesNotWaitForASlowPrimaryURL() async {
        let loader = BookCoverLoader()
        var cacheChecks: [String] = []
        let result = await loader.load(urls: [broken, replacement], identity: identity,
            cachedImageLoader: { url in
                cacheChecks.append(url)
                if url == broken { throw URLError(.resourceUnavailable) }
                return bitmap()
            }, imageLoader: { _ in
                Issue.record("A cached alternative must be displayed before starting network downloads")
                throw URLError(.timedOut)
            }, replacements: { _ in
                Issue.record("A saved cover must not require a catalog search")
                return []
            })
        #expect(result == replacement)
        #expect(cacheChecks == [broken, replacement])
        #expect(loader.image != nil)
        #expect(!loader.isLoading)
    }

    @Test func cacheMissStillDownloadsAndRejectsTinyCachedPlaceholders() async {
        let loader = BookCoverLoader()
        var downloads: [String] = []
        let result = await loader.load(urls: [broken, replacement], identity: identity,
            cachedImageLoader: { url in
                if url == broken { return bitmap(1) }
                throw URLError(.resourceUnavailable)
            }, imageLoader: { url in
                downloads.append(url)
                if url == broken { throw URLError(.fileDoesNotExist) }
                return bitmap()
            }, replacements: { _ in [] })
        #expect(result == replacement)
        #expect(downloads == [broken, replacement])
    }

    @Test func resolvingCatalogIdentityDoesNotReloadTheSameCover() async {
        let loader = BookCoverLoader()
        _ = await loader.load(urls: [replacement], identity: identity,
            imageLoader: { _ in bitmap() }, replacements: { _ in [] })
        let previous = loader.image
        let updated = BookCoverIdentity(title: identity.title, author: identity.author,
                                        isbn: identity.isbn, catalogID: "openlibrary:OL1W")
        let result = await loader.load(urls: [replacement], identity: updated,
            imageLoader: { _ in
                Issue.record("Catalog ID updates must not blank or reload a working cover")
                return bitmap()
            }, replacements: { _ in [] })
        #expect(result == replacement)
        #expect(loader.image === previous)
    }

    @Test func cacheOnlyUsesTheSameCacheWithoutStartingNetworkRequests() throws {
        let original = "https://covers.openlibrary.org/b/isbn/9780547773742-M.jpg"
        let pipeline = ImagePipeline()
        let oldRequest = try #require(BookCoverImage.imageRequest(original, width: 100, height: 150))
        let request = try #require(BookCoverImage.imageRequest(original, width: 100, height: 150, cacheOnly: true))
        #expect(pipeline.cache.makeDataCacheKey(for: request) == pipeline.cache.makeDataCacheKey(for: oldRequest))
        #expect(request.options.contains(.returnCacheDataDontLoad))
        #expect(request.url?.query == "default=false")
    }

    @Test func workingCoverNeverSearchesTheCatalog() async {
        let loader = BookCoverLoader()
        let result = await loader.load(urls: [broken], identity: identity, imageLoader: { _ in bitmap() }, replacements: { _ in
            Issue.record("Working covers must not trigger catalog requests")
            return []
        })
        #expect(result == broken)
        #expect(loader.image != nil)
        #expect(!loader.isLoading)
    }

    @Test func failedAndBlankImagesTryVerifiedAlternativesOnce() async {
        let loader = BookCoverLoader()
        var attempts: [String] = []
        let blank = "https://covers.openlibrary.org/b/id/999-M.jpg?default=false"
        let result = await loader.load(urls: [broken], identity: identity, imageLoader: { url in
            attempts.append(url)
            if url == broken { throw URLError(.fileDoesNotExist) }
            return bitmap(url == blank ? 1 : 40)
        }, replacements: { _ in [broken, blank, blank, replacement] })
        #expect(result == replacement)
        #expect(attempts == [broken, blank, replacement])
        #expect(loader.image != nil)
    }

    @Test func emptyCoverUsesCachedMetadataBeforeSearching() async {
        let loader = BookCoverLoader()
        let result = await loader.load(urls: ["", replacement], identity: identity, imageLoader: { _ in bitmap() }, replacements: { _ in
            Issue.record("A cached metadata cover should be tried before remote lookup")
            return []
        })
        #expect(result == replacement)
    }

    @Test func missingCoversFinishWithAPlaceholder() async {
        let loader = BookCoverLoader()
        let result = await loader.load(urls: [broken], identity: identity, imageLoader: { _ in
            throw URLError(.fileDoesNotExist)
        }, replacements: { _ in [broken] })
        #expect(result == nil)
        #expect(loader.image == nil)
        #expect(!loader.isLoading)
    }

    @Test func cancelledImageDoesNotStartFallbackOrPromoteAnImage() async {
        let loader = BookCoverLoader()
        let result = await loader.load(urls: [broken], identity: identity, imageLoader: { _ in
            throw CancellationError()
        }, replacements: { _ in
            Issue.record("Cancellation must not start a fallback")
            return [replacement]
        })
        #expect(result == nil)
        #expect(loader.image == nil)
        #expect(!loader.isLoading)
    }

    @Test func coverURLsPreventBlankResponsesAndKeepOtherQueryParameters() {
        #expect(BookCoverURL.normalized("http://covers.openlibrary.org/b/id/3-M.jpg?default=true&foo=bar") == "https://covers.openlibrary.org/b/id/3-M.jpg?foo=bar&default=false")
        #expect(BookCoverURL.normalized("file:///tmp/image.png") == nil)
        #expect(BookCoverURL.normalized("https://user:secret@example.com/cover.jpg") == nil)
    }

    @Test func repairedCoverPersistsWithoutChangingTheEditionOrSyncOutbox() async throws {
        let container = try ModelContainer(for: Book.self, Tag.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let book = Book(title: identity.title, author: identity.author, isbn: identity.isbn, coverURL: broken, googleBooksVolumeId: "storygraph:original")
        context.insert(book)
        try context.save()
        let operation = book.pendingOperationID
        book.rememberCover(replacement)
        try await Task.sleep(for: .milliseconds(450))
        let reopened = try #require(ModelContext(container).fetch(FetchDescriptor<Book>()).first)
        #expect(reopened.resolvedCoverURL == replacement)
        #expect(reopened.coverURL == broken)
        #expect(reopened.isbn == identity.isbn)
        #expect(reopened.googleBooksVolumeId == "storygraph:original")
        #expect(reopened.pendingOperationID == operation)
        #expect(reopened.pendingOperationData == nil)
        #expect(ReaderFavorite.cover(reopened) == replacement)
        #expect(BookDetailViewModel().coverURL(from: BookDetailViewModel().savedVolume(book: reopened)) == replacement)
    }
}
