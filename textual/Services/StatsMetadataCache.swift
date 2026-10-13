import Foundation
import SwiftData

/// Account-local SwiftData is the cache. Network work belongs to the account host,
/// not an individual chart or filter, and never clears previously saved metadata.
@MainActor
enum StatsMetadataCache {
    static let classificationVersion = 5
    static func needsLookup(hasCategories: Bool, hasPages: Bool, isAudio: Bool,
                            checkedAt: Date?, now: Date = Date()) -> Bool {
        if hasCategories && hasPages { return false }
        guard let checkedAt else { return true }
        return now.timeIntervalSince(checkedAt) >= 86_400
    }

    private static func metadata(_ book: Book) -> BookCatalogService.BookItem? {
        book.cachedCatalogMetadata.flatMap { try? JSONDecoder().decode(BookCatalogService.BookItem.self, from: $0) }
    }

    static func evidence(_ book: Book) -> BookCatalogService.ClassificationEvidence? {
        book.cachedStatsClassification.flatMap {
            try? JSONDecoder().decode(BookCatalogService.ClassificationEvidence.self, from: $0)
        }
    }

    static func genres(_ book: Book) -> Set<String> {
        if let evidence = evidence(book) {
            let genres = evidence.genres
            if !genres.isEmpty { return genres }
        }
        let saved = metadata(book)
        return GenreTaxonomy.normalized(saved?.volumeInfo?.catalogCategories ?? [], isOpenLibrary: saved?.id?.hasPrefix("openlibrary:") == true)
    }

    static func pageCount(_ book: Book) -> Int? {
        if let evidence = evidence(book), let pages = evidence.editionPages, pages > 0,
           let isbn = StoryGraphImporter.normalizedISBN(book.isbn), evidence.editionISBN == isbn { return pages }
        return metadata(book)?.volumeInfo?.pageCount.flatMap { $0 > 0 ? $0 : nil }
    }

    static func fictionKind(_ book: Book) -> BookFictionKind? {
        if let data = book.cachedStatsClassification,
           let evidence = try? JSONDecoder().decode(BookCatalogService.ClassificationEvidence.self, from: data),
           let kind = evidence.fictionKind { return kind }
        return BookFictionKind.classify(metadata(book)?.volumeInfo?.catalogCategories ?? [])
    }

    static func needsClassification(_ book: Book, googleConfigured: Bool = false, now: Date = Date()) -> Bool {
        if book.statsClassificationVersion < classificationVersion { return true }
        if googleConfigured && !book.statsClassificationUsedGoogleKey { return true }
        guard let checked = book.statsClassificationCheckedAt else { return true }
        if evidence(book)?.isComplete == true { return false }
        return now.timeIntervalSince(checked) >= 86_400
    }

    static func warm(_ books: [Book], service: BookCatalogService = .shared) async {
        let googleConfigured = await service.hasGoogleAPIKey
        let ordered = prioritizedForWarmup(books)
        await BookCatalogService.$isBackgroundLookup.withValue(true) {
            await warmBatches(ordered, service: service, googleConfigured: googleConfigured)
        }
    }

    static func prioritizedForWarmup(_ books: [Book]) -> [Book] {
        // Resolve visible gaps before rechecking already-classified reads or TBR.
        // Decode once per book, not inside the sort comparator.
        var ranked: [(book: Book, rank: Int, index: Int)] = []
        for (index, book) in books.enumerated() {
            let completed = book.importedReading.map { ReadingStatsFilter.completedCount($0) > 0 } == true
            let missing = fictionKind(book) == nil || genres(book).isEmpty
            let rank = completed ? (missing ? 0 : 1) : (missing ? 2 : 3)
            ranked.append((book, rank, index))
        }
        ranked.sort { lhs, rhs in
            lhs.rank == rhs.rank ? lhs.index < rhs.index : lhs.rank < rhs.rank
        }
        return ranked.map { $0.book }
    }

    private struct Pending {
        let original: Book
        let input: ReadingBookInput
        let catalogID: String?
        let prepared: Book
    }

    private static func warmBatches(_ books: [Book], service: BookCatalogService, googleConfigured: Bool) async {
        var pending: [Pending] = []
        var lastFlush = Date()
        func flush() {
            guard !Task.isCancelled else { return }
            var context: SwiftData.ModelContext?
            for item in pending {
                let book = item.original, prepared = item.prepared
                // A user edit/detail fetch that arrived during a lookup wins.
                guard !book.isRemovedFromLibrary, book.modelContext != nil,
                      book.googleBooksVolumeId == item.catalogID,
                      ReadingBookInput(book) == item.input else { continue }
                book.cachedStatsClassification = prepared.cachedStatsClassification
                book.statsClassificationCheckedAt = prepared.statsClassificationCheckedAt
                book.statsClassificationUsedGoogleKey = prepared.statsClassificationUsedGoogleKey
                book.statsClassificationVersion = prepared.statsClassificationVersion
                book.cachedCatalogMetadata = prepared.cachedCatalogMetadata
                book.catalogMetadataUpdatedAt = prepared.catalogMetadataUpdatedAt
                book.statsMetadataCheckedAt = prepared.statsMetadataCheckedAt
                book.statsMetadataVersion = prepared.statsMetadataVersion
                context = book.modelContext
            }
            try? context?.save()
            pending.removeAll(keepingCapacity: true)
            lastFlush = Date()
        }
        for original in books {
            guard !Task.isCancelled else { return }
            guard !original.isRemovedFromLibrary else { continue }
            let needsWork = needsClassification(original, googleConfigured: googleConfigured)
                || needsLookup(hasCategories: !genres(original).isEmpty, hasPages: pageCount(original) != nil,
                    isAudio: original.importedReading?.format.lowercased() == "audio",
                    checkedAt: original.statsMetadataVersion == 4 ? original.statsMetadataCheckedAt : nil)
            guard needsWork else { continue }
            let input = ReadingBookInput(original)
            // Detached, uninserted model: detail helpers cannot save or invalidate UI mid-lookup.
            let book = Book(id: original.id, title: original.title, author: original.author,
                isbn: original.isbn, coverURL: original.coverURL, googleBooksVolumeId: original.googleBooksVolumeId)
            book.resolvedCoverURL = original.resolvedCoverURL
            book.storyGraphData = original.storyGraphData
            book.cachedCatalogMetadata = original.cachedCatalogMetadata
            book.catalogMetadataUpdatedAt = original.catalogMetadataUpdatedAt
            book.cachedStatsClassification = original.cachedStatsClassification
            book.statsClassificationCheckedAt = original.statsClassificationCheckedAt
            book.statsClassificationUsedGoogleKey = original.statsClassificationUsedGoogleKey
            book.statsClassificationVersion = original.statsClassificationVersion
            book.statsMetadataCheckedAt = original.statsMetadataCheckedAt
            book.statsMetadataVersion = original.statsMetadataVersion
            await hydrate(book, service: service, googleConfigured: googleConfigured)
            guard !Task.isCancelled else { return }
            pending.append(Pending(original: original, input: input, catalogID: book.googleBooksVolumeId, prepared: book))
            if pending.count >= 5 || Date().timeIntervalSince(lastFlush) >= 5 { flush() }
            await Task.yield()
        }
        flush()
    }

    private static func hydrate(_ book: Book, service: BookCatalogService, googleConfigured: Bool) async {
        if needsClassification(book, googleConfigured: googleConfigured) {
            let saved = metadata(book)
            do {
                let lookup = try await service.classificationLookup(isbn: book.isbn, title: book.title, author: book.author,
                    savedCategories: saved?.volumeInfo?.catalogCategories ?? [],
                    savedSource: saved?.id?.hasPrefix("openlibrary:") == true ? "openlibrary" : "google")
                if let evidence = lookup.evidence {
                    guard !Task.isCancelled, !book.isRemovedFromLibrary else { return }
                    // A partial refresh supplements previously verified fields.
                    // It must not erase a genre just because a provider failed.
                    let merged = evidence.supplemented(with: self.evidence(book) ?? evidence)
                    book.cachedStatsClassification = try JSONEncoder().encode(merged)
                }
                book.statsClassificationCheckedAt = lookup.retryRequired ? nil : Date()
                book.statsClassificationUsedGoogleKey = lookup.usedGoogleKey
                book.statsClassificationVersion = classificationVersion
            } catch {
                guard !Task.isCancelled else { return }
                // Failed requests remain retryable on the next account warmup.
            }
        }
        let info = metadata(book)?.volumeInfo
        let isAudio = book.importedReading?.format.lowercased() == "audio"
        guard needsLookup(hasCategories: !genres(book).isEmpty,
                          hasPages: pageCount(book) != nil, isAudio: isAudio,
                          checkedAt: book.statsMetadataVersion == 4 ? book.statsMetadataCheckedAt : nil) else { return }
        if info?.categories?.isEmpty != false {
            await BookDetailViewModel(booksService: service).fetchVolume(book: book, forceRefresh: true)
        }
        guard !Task.isCancelled, !book.isRemovedFromLibrary else { return }
        if pageCount(book) == nil,
           let count = try? await service.editionPageCount(isbn: book.isbn, title: book.title, author: book.author),
           var updated = BookDetailViewModel().savedVolume(book: book).volumeInfo {
            guard !Task.isCancelled, !book.isRemovedFromLibrary else { return }
            updated.pageCount = count
            let item = BookCatalogService.BookItem(id: metadata(book)?.id, volumeInfo: updated)
            if let encoded = try? JSONEncoder().encode(item) { book.cachedCatalogMetadata = encoded }
        }
        guard !Task.isCancelled else { return }
        if pageCount(book) == nil, evidence(book)?.workPageCounts?.isEmpty != false,
           let counts = try? await service.estimatedPageCounts(isbn: book.isbn, title: book.title, author: book.author),
           !counts.isEmpty {
            guard !Task.isCancelled, !book.isRemovedFromLibrary else { return }
            var updated = evidence(book) ?? .init(categories: [], source: "openlibrary")
            updated.workPageCounts = counts
            book.cachedStatsClassification = try? JSONEncoder().encode(updated)
        }
        guard !Task.isCancelled else { return }
        book.statsMetadataCheckedAt = Date()
        book.statsMetadataVersion = 4
    }
}
