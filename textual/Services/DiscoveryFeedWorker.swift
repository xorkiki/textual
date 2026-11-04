import Foundation

/// Capture raw values on the model context; decoding and classification belong
/// to the account's worker. No SwiftData model crosses the actor boundary.
struct DiscoveryTasteInput: Equatable, Sendable {
    let book: ReadingBookInput
    let catalogID: String?
    let pendingReview: Data?
    let remoteReview: Data?

    @MainActor init(book: Book, draft: ReaderReviewDraft?) {
        self.book = ReadingBookInput(book)
        catalogID = book.googleBooksVolumeId
        pendingReview = draft?.pendingData
        remoteReview = draft?.remoteData
    }
}

struct DiscoveryPool: Sendable {
    let collection: DiscoveryCollection
    let items: [DiscoverItem]
    let fetchedAt: Date?
}

struct DiscoveryRanking: Sendable {
    let recommendations: [DiscoveryRecommendation]
    let signature: String
}

/// Account-scoped, bounded memoization. Both Explore and For You use this actor,
/// including their preparation, instead of doing classification in view updates.
actor DiscoveryFeedWorker {
    private struct GenreKey: Hashable {
        let subjects: [String]
        let openLibrary: Bool
    }
    private var genreCache: [GenreKey: Set<String>] = [:]
    private var exploreInput: [DiscoverItem]?
    private var exploreSeed: UInt64?
    private var exploreResult: [DiscoverItem] = []

    private struct TasteRecord {
        let input: ReadingBookInput
        let reading: StoryGraphReadingData?
        let metadataID: String?
        let genres: Set<String>
    }
    private var tasteRecords: [UUID: TasteRecord] = [:]

    private func genres(_ subjects: [String], openLibrary: Bool) -> Set<String> {
        let key = GenreKey(subjects: subjects, openLibrary: openLibrary)
        if let value = genreCache[key] { return value }
        let value = GenreTaxonomy.normalized(subjects, isOpenLibrary: openLibrary)
        if genreCache.count >= 4_096 { genreCache.removeAll(keepingCapacity: true) }
        genreCache[key] = value
        return value
    }

    func explore(_ items: [DiscoverItem], seed: UInt64) throws -> [DiscoverItem] {
        try Task.checkCancellation()
        if exploreSeed == seed, exploreInput == items { return exploreResult }
        let result = DiscoveryExploreOrder.order(items, seed: seed, genres: {
            self.genres($0.subjects, openLibrary: true)
        })
        try Task.checkCancellation()
        exploreInput = items
        exploreSeed = seed
        exploreResult = result
        return result
    }

    func taste(_ inputs: [DiscoveryTasteInput], profileData: Data?) throws -> [DiscoveryTasteBook] {
        try Task.checkCancellation()
        let decoder = JSONDecoder()
        let favorites = profileData.flatMap { try? decoder.decode(ReaderPublicContent.self, from: $0) }?.favorites ?? []
        var matched = Set<UUID>()
        var nextRecords: [UUID: TasteRecord] = [:]
        var result: [DiscoveryTasteBook] = []
        for input in inputs {
            try Task.checkCancellation()
            let book = input.book
            let record: TasteRecord
            if let cached = tasteRecords[book.id], cached.input == book {
                record = cached
            } else {
                let metadata = book.metadata.flatMap { try? decoder.decode(BookCatalogService.BookItem.self, from: $0) }
                let evidence = book.classification.flatMap { try? decoder.decode(BookCatalogService.ClassificationEvidence.self, from: $0) }
                let knownGenres = evidence?.genres ?? []
                record = TasteRecord(input: book,
                    reading: book.readingData.flatMap { try? decoder.decode(StoryGraphReadingData.self, from: $0) },
                    metadataID: metadata?.id,
                    genres: knownGenres.isEmpty
                        ? genres(metadata?.volumeInfo?.catalogCategories ?? [], openLibrary: metadata?.id?.hasPrefix("openlibrary:") == true)
                        : knownGenres)
            }
            nextRecords[book.id] = record
            // Match ReaderFavorite.matches without decoding the same metadata for
            // each favorite or touching a live Book on this actor.
            let rank = favorites.firstIndex {
                $0.id == book.id || ($0.catalogID != nil && ($0.catalogID == input.catalogID || $0.catalogID == record.metadataID))
                    || (!$0.isbn.isEmpty && $0.isbn == book.isbn)
            }
            if let rank { matched.insert(favorites[rank].id) }
            let pending = input.pendingReview.flatMap { try? decoder.decode(ReaderReviewMutation.self, from: $0) }
            let remote = input.remoteReview.flatMap { try? decoder.decode(RemoteReaderReview.self, from: $0) }
            let rating: Double?
            if let pending {
                rating = pending.deleted ? nil : pending.content.rating.map { Double($0) / 4 }
            } else if let remote {
                rating = remote.deleted ? nil : remote.content.rating.map { Double($0) / 4 }
            } else if let imported = record.reading?.rating, imported.isFinite, (0...5).contains(imported) {
                rating = (imported * 4).rounded() / 4
            } else { rating = nil }
            result.append(DiscoveryTasteBook(catalogID: input.catalogID, title: book.title, author: book.author,
                isbns: [book.isbn], genres: record.genres, status: record.reading?.status,
                rating: rating, favoriteRank: rank))
        }
        for (rank, favorite) in favorites.enumerated() where !matched.contains(favorite.id) {
            result.append(DiscoveryTasteBook(catalogID: favorite.catalogID, title: favorite.title,
                author: favorite.author, isbns: [favorite.isbn], favoriteRank: rank))
        }
        try Task.checkCancellation()
        tasteRecords = nextRecords
        return result
    }

    func favoriteAuthors(_ taste: [DiscoveryTasteBook]) throws -> [String] {
        try Task.checkCancellation()
        let profile = DiscoveryRecommender.profile(taste)
        var names: [String: String] = [:]
        for book in taste {
            try Task.checkCancellation()
            let key = DiscoveryIdentity.primaryAuthorKey(book.author)
            names[key] = names[key] ?? book.author.components(separatedBy: ",").first
        }
        return profile.authors.filter { $0.value >= 4 && $0.key != "unknown author" }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(4)
            .compactMap { names[$0.key]?.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func rank(taste: [DiscoveryTasteBook], pools: [DiscoveryPool], seed: UInt64,
              previousSignature: String?, hasCachedResults: Bool) throws -> DiscoveryRanking? {
        try Task.checkCancellation()
        let poolStamp = pools.map { "\($0.collection.rawValue):\($0.fetchedAt?.timeIntervalSince1970 ?? 0)" }
        let tasteStamp = taste.map {
            "\($0.catalogID ?? "")|\($0.title)|\($0.author)|\($0.isbns.joined(separator: ","))|\($0.status ?? "")|\($0.rating ?? -1)|\($0.favoriteRank ?? -1)|\($0.genres.sorted().joined(separator: ","))"
        }.sorted()
        let signature = DiscoverySeed.signature(["v2", String(seed)] + poolStamp + tasteStamp)
        if hasCachedResults, previousSignature == signature { return nil }
        var collections: [String: Set<String>] = [:]
        var items: [String: DiscoverItem] = [:]
        for pool in pools {
            for item in pool.items {
                try Task.checkCancellation()
                items[item.catalogID] = items[item.catalogID] ?? item
                collections[item.catalogID, default: []].insert(pool.collection == .forYouAuthors ? "author" : pool.collection.rawValue)
            }
        }
        guard !items.isEmpty else { return nil }
        var candidates: [DiscoveryCandidate] = []
        for item in items.values {
            try Task.checkCancellation()
            candidates.append(DiscoveryCandidate(item: item, collections: collections[item.catalogID] ?? [],
                genres: genres(item.subjects, openLibrary: item.catalogID.hasPrefix("openlibrary:") || item.facet != nil)))
        }
        candidates.sort { $0.item.catalogID < $1.item.catalogID }
        let ranked = DiscoveryRecommender.recommend(books: taste, candidates: candidates, seed: seed)
        try Task.checkCancellation()
        return DiscoveryRanking(recommendations: ranked, signature: signature)
    }
}
