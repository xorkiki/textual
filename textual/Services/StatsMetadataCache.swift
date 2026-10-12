import Foundation

/// Account-local SwiftData is the cache. Network work belongs to the account host,
/// not an individual chart or filter, and never clears previously saved metadata.
@MainActor
enum StatsMetadataCache {
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
            let genres = GenreTaxonomy.normalized(evidence.categories, isOpenLibrary: evidence.source == "openlibrary")
            if !genres.isEmpty { return genres }
        }
        let saved = metadata(book)
        return GenreTaxonomy.normalized(saved?.volumeInfo?.categories ?? [], isOpenLibrary: saved?.id?.hasPrefix("openlibrary:") == true)
    }

    static func pageCount(_ book: Book) -> Int? {
        if let evidence = evidence(book), let pages = evidence.editionPages, pages > 0,
           let isbn = StoryGraphImporter.normalizedISBN(book.isbn), evidence.editionISBN == isbn { return pages }
        return metadata(book)?.volumeInfo?.pageCount.flatMap { $0 > 0 ? $0 : nil }
    }

    static func fictionKind(_ book: Book) -> BookFictionKind? {
        if let data = book.cachedStatsClassification,
           let evidence = try? JSONDecoder().decode(BookCatalogService.ClassificationEvidence.self, from: data),
           let kind = BookFictionKind.classify(evidence.categories) { return kind }
        return BookFictionKind.classify(metadata(book)?.volumeInfo?.categories ?? [])
    }

    static func needsClassification(_ book: Book, googleConfigured: Bool = false, now: Date = Date()) -> Bool {
        if let data = book.cachedStatsClassification,
           let evidence = try? JSONDecoder().decode(BookCatalogService.ClassificationEvidence.self, from: data),
           evidence.source == "google", !evidence.categories.isEmpty { return false }
        if googleConfigured && (!book.statsClassificationUsedGoogleKey || book.statsClassificationVersion < 1) { return true }
        guard let checked = book.statsClassificationCheckedAt else { return true }
        return now.timeIntervalSince(checked) >= 86_400
    }

    static func warm(_ books: [Book], service: BookCatalogService = .shared) async {
        let googleConfigured = await service.hasGoogleAPIKey
        let ordered = books.sorted {
            ($0.importedReading.map { ReadingStatsFilter.completedCount($0) > 0 } == true ? 0 : 1) < ($1.importedReading.map { ReadingStatsFilter.completedCount($0) > 0 } == true ? 0 : 1)
        }
        for book in ordered {
            guard !Task.isCancelled else { return }
            guard !book.isRemovedFromLibrary, book.importedReading != nil else { continue }
            if needsClassification(book, googleConfigured: googleConfigured) {
                let saved = metadata(book)
                do {
                    if let evidence = try await service.classification(isbn: book.isbn, title: book.title, author: book.author,
                        savedCategories: saved?.volumeInfo?.categories ?? [],
                        savedSource: saved?.id?.hasPrefix("openlibrary:") == true ? "openlibrary" : "google") {
                        guard !Task.isCancelled, !book.isRemovedFromLibrary else { return }
                        book.cachedStatsClassification = try JSONEncoder().encode(evidence)
                    }
                    book.statsClassificationCheckedAt = Date()
                    book.statsClassificationUsedGoogleKey = googleConfigured
                    book.statsClassificationVersion = 1
                    try? book.modelContext?.save()
                } catch {
                    guard !Task.isCancelled else { return }
                    // Failed requests remain retryable on the next account warmup.
                }
            }
            let info = metadata(book)?.volumeInfo
            let isAudio = book.importedReading?.format.lowercased() == "audio"
            guard needsLookup(hasCategories: !genres(book).isEmpty,
                              hasPages: pageCount(book) != nil, isAudio: isAudio,
                              checkedAt: book.statsMetadataVersion == 3 ? book.statsMetadataCheckedAt : nil) else { continue }
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
            book.statsMetadataCheckedAt = Date()
            book.statsMetadataVersion = 3
            try? book.modelContext?.save()
        }
    }
}
