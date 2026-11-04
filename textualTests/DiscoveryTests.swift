import XCTest
import SwiftData
@testable import textual

private func item(_ id: String, title: String? = nil, author: String = "Writer", isbns: [String] = [],
                  aspect: Double = 1.5, subjects: [String] = [], facet: String? = nil, sources: [String] = [],
                  popularity: Int = 10, year: Int? = 2001, expiresAt: Date? = nil) -> DiscoverItem {
    DiscoverItem(catalogID: id, title: title ?? "Title \(id)", author: author, isbns: isbns,
                 coverURL: "https://covers.openlibrary.org/b/id/\(id.utf8.count)-L.jpg", aspect: aspect,
                 firstPublishedYear: year, subjects: subjects, facet: facet, sources: sources,
                 popularity: popularity, expiresAt: expiresAt)
}

final class MasonryLayoutTests: XCTestCase {
    func testShortestColumnPlacementBalancesHeights() {
        let columns = MasonryLayout.assign(aspects: [1.5, 1.0, 1.0, 1.5, 0.5], columns: 2)
        XCTAssertEqual(columns, [[0, 3], [1, 2, 4]])
    }

    func testAppendingPagesNeverMovesEarlierItems() {
        let aspects = (0..<60).map { 1 + Double(($0 * 7) % 10) / 10 }
        let first = MasonryLayout.assign(aspects: Array(aspects.prefix(24)), columns: 2)
        let extended = MasonryLayout.extend(first, previousCount: 24, aspects: aspects, columns: 2)
        for column in 0..<2 { XCTAssertEqual(Array(extended[column].prefix(first[column].count)), first[column]) }
        XCTAssertEqual(extended, MasonryLayout.assign(aspects: aspects, columns: 2), "extension equals a full layout")
        XCTAssertEqual(Set(extended.flatMap { $0 }), Set(0..<60))
    }

    func testMismatchedHistoryFallsBackToFullLayout() {
        let aspects = [1.5, 1.5, 1.5]
        XCTAssertEqual(MasonryLayout.extend([[0]], previousCount: 2, aspects: aspects, columns: 2),
                       MasonryLayout.assign(aspects: aspects, columns: 2))
    }
}

@MainActor
final class DiscoveryIdentityTests: XCTestCase {
    func testKeysIgnoreSubtitlesSeriesArticlesAndInitialSpacing() {
        XCTAssertEqual(DiscoveryIdentity.titleKey("The Hobbit: Or There and Back Again"), "hobbit")
        XCTAssertEqual(DiscoveryIdentity.titleKey("Onyx Storm (The Empyrean, #3)"), "onyx storm")
        XCTAssertEqual(DiscoveryIdentity.authorKey("J.R.R. Tolkien"), DiscoveryIdentity.authorKey("J. R. R. Tolkien"))
        XCTAssertNotEqual(DiscoveryIdentity.authorKey("John Green"), DiscoveryIdentity.authorKey("Jane Green"))
    }

    func testArchiveMatchingUsesCatalogIDThenISBNThenExactWork() throws {
        let container = try ModelContainer(for: Book.self, Tag.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let byID = Book(title: "Alpha", author: "A Writer", isbn: "", googleBooksVolumeId: "openlibrary:OL1W")
        let byISBN = Book(title: "Beta", author: "B Writer", isbn: "978-0-385-55055-0", googleBooksVolumeId: "vol1")
        let byWork = Book(title: "The Gamma: A Novel", author: "C. Writer", isbn: "", googleBooksVolumeId: "vol2")
        let removed = Book(title: "Delta", author: "D Writer", isbn: "", googleBooksVolumeId: "openlibrary:OL4W")
        removed.isRemovedFromLibrary = true
        [byID, byISBN, byWork, removed].forEach(container.mainContext.insert)
        let index = DiscoveryArchiveIndex(books: [byID, byISBN, byWork, removed])

        XCTAssertTrue(index.book(for: item("openlibrary:OL1W")) === byID)
        XCTAssertTrue(index.book(for: item("openlibrary:OL9W", isbns: ["9780385550550"])) === byISBN)
        XCTAssertTrue(index.book(for: item("openlibrary:OL8W", title: "Gamma", author: "C Writer")) === byWork)
        XCTAssertNil(index.book(for: item("openlibrary:OL7W", title: "Gamma Ray", author: "C Writer")), "similar title")
        XCTAssertNil(index.book(for: item("openlibrary:OL6W", title: "Gamma", author: "Other Writer")), "other author")
        XCTAssertNil(index.book(for: item("openlibrary:OL4W")), "removed books are not in the archive")
    }

    func testAmbiguousTitleAuthorMatchesAreNotGuessed() throws {
        let container = try ModelContainer(for: Book.self, Tag.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let a = Book(title: "Poems", author: "Writer", isbn: "", googleBooksVolumeId: "v1")
        let b = Book(title: "Poems", author: "Writer", isbn: "", googleBooksVolumeId: "v2")
        [a, b].forEach(container.mainContext.insert)
        XCTAssertNil(DiscoveryArchiveIndex(books: [a, b]).book(for: item("openlibrary:OL5W", title: "Poems")))
    }

    func testWireRowsMapToExistingCatalogIDsAndRejectBadRows() throws {
        let json = """
        {"collection":"trending","refreshed_at":"2026-10-12T10:00:00.123456+00:00","total":3,"attribution":[],
         "books":[
          {"provider":"openlibrary","provider_id":"OL123W","title":"Verity","author":"Colleen Hoover","isbns":["9781538724743"],
           "cover_url":"https://covers.openlibrary.org/b/id/10-L.jpg","cover_width":320,"cover_height":480,
           "first_published_year":2018,"subjects":["Fiction"],"popularity":4,"position":0,"sources":["apple"],"facet":null,
           "expires_at":"2026-10-13T10:00:00+00:00"},
          {"provider":"google","provider_id":"abc_DEF","title":"G","author":"A","isbns":[],
           "cover_url":"https://books.google.com/books/content?id=abc_DEF&fife=w800","cover_width":400,"cover_height":600,
           "first_published_year":null,"subjects":[],"popularity":0,"position":1,"sources":[],"facet":null,"expires_at":null},
          {"provider":"openlibrary","provider_id":"bad","title":"Bad","author":"A","isbns":[],
           "cover_url":"https://covers.openlibrary.org/b/id/1-L.jpg","cover_width":1,"cover_height":1,
           "first_published_year":null,"subjects":[],"popularity":0,"position":2,"sources":[],"facet":null,"expires_at":null}]}
        """
        let page = try JSONDecoder().decode(DiscoveryPage.self, from: Data(json.utf8))
        let items = page.books.compactMap(\.item)
        XCTAssertEqual(items.map(\.catalogID), ["openlibrary:OL123W", "abc_DEF"])
        XCTAssertEqual(items[0].aspect, 1.5, accuracy: 0.0001)
        XCTAssertNotNil(items[0].expiresAt)
        XCTAssertNotNil(page.refreshedAt.flatMap(DiscoveryDate.parse))
        XCTAssertEqual(items[0].catalogBook().googleBooksVolumeId, "openlibrary:OL123W")
    }
}

private actor FakeDiscoveryTransport: DiscoveryTransport {
    private var pages: [DiscoveryCollection: [String]] = [:]
    private var fails = false
    private(set) var offsets: [Int] = []

    func set(_ collection: DiscoveryCollection, _ rows: [String]) { pages[collection] = rows }
    func setFails(_ value: Bool) { fails = value }

    func page(_ collection: DiscoveryCollection, offset: Int, limit: Int) async throws -> DiscoveryPage {
        offsets.append(offset)
        if fails { throw URLError(.notConnectedToInternet) }
        let all = pages[collection] ?? []
        let books = all.dropFirst(offset).prefix(limit).joined(separator: ",")
        let json = #"{"collection":"\#(collection.rawValue)","refreshed_at":"2026-10-12T10:00:00+00:00","total":\#(all.count),"attribution":[],"books":[\#(books)]}"#
        return try JSONDecoder().decode(DiscoveryPage.self, from: Data(json.utf8))
    }
}

/// One wire row as JSON text.
private func row(_ id: String, expires: String? = nil) -> String {
    #"{"provider":"openlibrary","provider_id":"\#(id)","title":"Title \#(id)","author":"Writer","isbns":[],"cover_url":"https://covers.openlibrary.org/b/id/1-L.jpg","cover_width":300,"cover_height":450,"first_published_year":null,"subjects":[],"popularity":1,"position":0,"sources":[],"facet":null,"expires_at":\#(expires.map { "\"\($0)\"" } ?? "null")}"#
}

@MainActor
final class DiscoveryRepositoryTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeRepository(_ transport: FakeDiscoveryTransport) throws -> (ModelContainer, DiscoveryRepository) {
        let container = try ModelContainer(for: DiscoveryCacheEntry.self, DiscoveryCollectionState.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let repository = DiscoveryRepository(context: container.mainContext, transport: transport, now: { [unowned self] in self.clock })
        return (container, repository)
    }

    func testRefreshCachesPagesInOrderAndThrottles() async throws {
        let transport = FakeDiscoveryTransport()
        await transport.set(.trending, (1...450).map { row("OL\($0)W") })
        let (container, repository) = try makeRepository(transport)
        defer { withExtendedLifetime(container) {} }
        await repository.refresh(.trending)
        XCTAssertEqual(repository.items(.trending).count, 450)
        XCTAssertEqual(repository.items(.trending).first?.catalogID, "openlibrary:OL1W")
        var offsets = await transport.offsets
        XCTAssertEqual(offsets, [0, 200, 400], "pages until the total")
        await repository.refresh(.trending)
        offsets = await transport.offsets
        XCTAssertEqual(offsets.count, 3, "fresh cache is not refetched")
        await repository.refresh(.trending, force: true)
        offsets = await transport.offsets
        XCTAssertEqual(offsets.count, 6, "pull to refresh bypasses freshness")
    }

    func testFailureKeepsCacheAndBacksOff() async throws {
        let transport = FakeDiscoveryTransport()
        await transport.set(.explore, [row("OL1W"), row("OL2W")])
        let (container, repository) = try makeRepository(transport)
        defer { withExtendedLifetime(container) {} }
        await repository.refresh(.explore)
        await transport.setFails(true)
        clock += DiscoveryCollection.explore.freshness + 1
        await repository.refresh(.explore)
        XCTAssertEqual(repository.items(.explore).count, 2, "cached books survive a failed refresh")
        XCTAssertTrue(repository.failed.contains(.explore))
        let count = await transport.offsets.count
        await repository.refresh(.explore)
        let retried = await transport.offsets.count
        XCTAssertEqual(retried, count, "backoff prevents rapid retries")
        clock += DiscoveryRepository.backoff(failures: 1) + 1
        await transport.setFails(false)
        await repository.refresh(.explore)
        XCTAssertFalse(repository.failed.contains(.explore))
    }

    func testExpiredProviderRowsAreHiddenAndReplacementRemovesStaleRows() async throws {
        let transport = FakeDiscoveryTransport()
        let soon = ISO8601DateFormatter().string(from: clock.addingTimeInterval(3600))
        await transport.set(.trending, [row("OL1W", expires: soon), row("OL2W")])
        let (container, repository) = try makeRepository(transport)
        defer { withExtendedLifetime(container) {} }
        await repository.refresh(.trending)
        XCTAssertEqual(repository.items(.trending).count, 2)
        clock += 7200
        XCTAssertEqual(repository.items(.trending).map(\.catalogID), ["openlibrary:OL2W"], "24-hour NYT rule")
        await transport.set(.trending, [row("OL3W"), row("OL2W")])
        await repository.refresh(.trending, force: true)
        XCTAssertEqual(repository.entries(.trending).map(\.catalogID), ["openlibrary:OL3W", "openlibrary:OL2W"])
    }

    func testEmptyCollectionIsRetriedInsteadOfCachedAsFresh() async throws {
        let transport = FakeDiscoveryTransport()
        let (container, repository) = try makeRepository(transport)
        defer { withExtendedLifetime(container) {} }
        await repository.refresh(.trending)
        XCTAssertTrue(repository.failed.contains(.trending), "not filled yet is shown as retryable")
        XCTAssertNil(repository.state(.trending)?.fetchedAt, "an empty answer is never fresh")
        await transport.set(.trending, [row("OL1W")])
        clock += DiscoveryRepository.backoff(failures: 1) + 1
        await repository.refresh(.trending)
        XCTAssertEqual(repository.items(.trending).map(\.catalogID), ["openlibrary:OL1W"])
        XCTAssertFalse(repository.failed.contains(.trending))
    }

    func testUnchangedRefreshAndRankingOutputDoNotRestartUnrelatedFeeds() async throws {
        let transport = FakeDiscoveryTransport()
        await transport.set(.explore, [row("OL1W")])
        let (container, repository) = try makeRepository(transport)
        defer { withExtendedLifetime(container) {} }
        await repository.refresh(.explore)
        let exploreVersion = repository.collectionRevision(.explore)
        let inputVersion = repository.rankingInputRevision
        await repository.refresh(.explore, force: true)
        XCTAssertEqual(repository.collectionRevision(.explore), exploreVersion)
        XCTAssertEqual(repository.rankingInputRevision, inputVersion)
        try repository.store([(item("ranked"), [])], in: .forYou, signature: "sig")
        try repository.store([(item("author"), [])], in: .forYouAuthors, signature: "authors")
        XCTAssertEqual(repository.rankingInputRevision, inputVersion, "Output must not restart its own producer")
        XCTAssertEqual(repository.collectionRevision(.explore), exploreVersion)
        XCTAssertEqual(repository.items(.forYou).map(\.id), ["ranked"])
        try repository.store([(item("replacement"), [])], in: .forYou, signature: "next")
        XCTAssertEqual(repository.items(.forYou).map(\.id), ["replacement"], "Value cache invalidates after a write")
        await transport.set(.explore, [row("OL2W")])
        await repository.refresh(.explore, force: true)
        XCTAssertGreaterThan(repository.rankingInputRevision, inputVersion)
        XCTAssertEqual(repository.items(.explore).map(\.id), ["openlibrary:OL2W"])
    }

    func testLocalRankingsAreStoredWithSignatureAndReasons() throws {
        let (container, repository) = try makeRepository(FakeDiscoveryTransport())
        defer { withExtendedLifetime(container) {} }
        try repository.store([(item("a"), ["personal", "author:A"]), (item("b"), ["exploratory"]), (item("a"), [])],
                             in: .forYou, signature: "sig")
        XCTAssertEqual(repository.items(.forYou).map(\.catalogID), ["a", "b"])
        XCTAssertEqual(repository.entries(.forYou).first?.reasons, ["personal", "author:A"])
        XCTAssertEqual(repository.state(.forYou)?.inputSignature, "sig")
        try repository.store([(item("x"), [])], in: .trending, signature: "ignored")
        XCTAssertTrue(repository.items(.trending).isEmpty, "server collections are never written locally")
    }
}

@MainActor
final class DiscoverFeedTests: XCTestCase {
    func testNewRankingWaitsUntilAdoptedButAppendsSilently() {
        let feed = DiscoverFeed()
        let first = (0..<30).map { item("b\($0)") }
        feed.offer(first)
        XCTAssertEqual(feed.visibleItems.count, DiscoverFeed.pageSize)
        feed.loadMore()
        XCTAssertEqual(feed.visibleItems.count, 30)

        feed.offer(first + [item("b30")])
        XCTAssertEqual(feed.items.count, 31, "same visible prefix updates silently")
        XCTAssertEqual(feed.generation, 0)

        feed.offer(Array(first.reversed()))
        XCTAssertEqual(feed.visibleItems.first?.id, "b0", "no reordering while browsing")
        feed.adoptPending()
        XCTAssertEqual(feed.visibleItems.first?.id, "b29")
        XCTAssertEqual(feed.generation, 1)
        XCTAssertEqual(feed.visibleItems.count, DiscoverFeed.pageSize)
    }
}

final class DiscoveryExploreOrderTests: XCTestCase {
    private let pool: [DiscoverItem] = ["poetry", "history", "science", "pre-1900"].flatMap { facet in
        (0..<10).map { item("\(facet)-\($0)", author: "\(facet) author \($0 % 5)", facet: facet, popularity: $0 * 10) }
    }

    func testSeededOrderIsStableAndVariesBySession() {
        let a = DiscoveryExploreOrder.order(pool, seed: 1)
        XCTAssertEqual(a.map(\.id), DiscoveryExploreOrder.order(pool, seed: 1).map(\.id))
        XCTAssertNotEqual(a.prefix(20).map(\.id), DiscoveryExploreOrder.order(pool, seed: 2).prefix(20).map(\.id))
        XCTAssertEqual(Set(a.map(\.id)).count, pool.count)
    }

    func testFacetsInterleaveAndAuthorsDoNotCluster() {
        let order = DiscoveryExploreOrder.order(pool, seed: 7)
        XCTAssertEqual(Set(order.prefix(4).compactMap(\.facet)).count, 4, "every pool appears up front")
        for window in 0..<(order.count - 2) {
            let authors = order[window..<(window + 2)].map(\.author)
            XCTAssertNotEqual(authors[0], authors[1])
        }
    }

    func testChildrensBooksAndDuplicatesAreLeftOut() {
        let kids = item("k", subjects: ["Juvenile fiction"], facet: "poetry")
        let duplicate = item("dup", title: "Title poetry-1", author: "poetry author 1", facet: "history")
        let order = DiscoveryExploreOrder.order(pool + [kids, duplicate], seed: 3)
        XCTAssertFalse(order.contains { $0.id == "k" })
        XCTAssertEqual(order.filter { $0.title == "Title poetry-1" }.count, 1)
    }
}

final class DiscoveryRecommenderTests: XCTestCase {
    private func candidate(_ id: String, author: String = "Someone", subjects: [String], collection: String = "explore",
                           popularity: Int = 50) -> DiscoveryCandidate {
        DiscoveryCandidate(item: item(id, author: author, subjects: subjects, facet: collection == "explore" ? "x" : nil,
                                      popularity: popularity), collections: [collection])
    }

    private lazy var pool: [DiscoveryCandidate] = {
        var result: [DiscoveryCandidate] = []
        for i in 0..<20 { result.append(candidate("fantasy\(i)", author: "Fantasy Writer \(i % 6)", subjects: ["Fantasy"])) }
        for i in 0..<12 { result.append(candidate("newfantasy\(i)", author: "New Fantasist \(i % 6)", subjects: ["Fantasy"])) }
        for i in 0..<20 { result.append(candidate("history\(i)", author: "Historian \(i % 6)", subjects: ["History"])) }
        for i in 0..<20 { result.append(candidate("romance\(i)", author: "Romance Writer \(i % 6)", subjects: ["Romance"], collection: "trending")) }
        for i in 0..<20 { result.append(candidate("poetry\(i)", author: "Poet \(i % 6)", subjects: ["Poetry"], collection: "new_releases")) }
        result.append(candidate("loved-author", author: "Ursula K. Le Guin", subjects: ["Science fiction"]))
        return result
    }()

    func testEmptyArchiveGetsDiverseNonEmptyRecommendations() {
        let result = DiscoveryRecommender.recommend(books: [], candidates: pool, seed: 1, limit: 40)
        XCTAssertEqual(result.count, 40)
        XCTAssertTrue(result.allSatisfy { !$0.personal }, "no personalization without signals")
        let genres = Set(result.prefix(12).flatMap { GenreTaxonomy.normalized($0.item.subjects, isOpenLibrary: true) })
        XCTAssertGreaterThanOrEqual(genres.count, 3, "cold start spans genres")
        let sources = Set(result.prefix(20).compactMap { r in pool.first { $0.item.id == r.item.id }?.collections.first })
        XCTAssertEqual(sources, ["explore", "trending", "new_releases"])
    }

    func testPersonalizationGrowsWithSignal() {
        XCTAssertEqual(DiscoveryRecommender.personalShare(strength: 0), 0)
        let small = DiscoveryRecommender.personalShare(strength: 6)
        XCTAssertGreaterThan(small, 0)
        XCTAssertLessThan(small, DiscoveryRecommender.maximumPersonalShare)
        XCTAssertEqual(DiscoveryRecommender.personalShare(strength: 200), 0.7, accuracy: 0.0001)
    }

    func testFavoritesAndRatingsShapeTheTopAndRespectTheExploratoryShare() {
        let books = (0..<6).map {
            DiscoveryTasteBook(catalogID: "own\($0)", title: "Own \($0)", author: "Archive Fantasist \($0)",
                               genres: ["Fantasy"], status: "read", rating: 5, favoriteRank: $0 < 3 ? $0 + 1 : nil)
        } + [DiscoveryTasteBook(catalogID: "own-lg", title: "The Left Hand of Darkness", author: "Ursula K. Le Guin",
                                genres: ["Science fiction"], status: "read", rating: 5, favoriteRank: 0)]
        let result = DiscoveryRecommender.recommend(books: books, candidates: pool, seed: 1, limit: 40)
        XCTAssertEqual(result.first?.item.id, "loved-author", "a top-five favorite author leads")
        XCTAssertGreaterThanOrEqual(result.prefix(10).filter { $0.item.subjects == ["Fantasy"] }.count, 4, "favorite genre follows")
        let personal = result.prefix(20).filter(\.personal).count
        XCTAssertTrue((12...16).contains(personal), "about 70% personal, 30% exploratory: \(personal)/20")
        XCTAssertTrue(result.prefix(20).contains { !$0.personal && $0.item.subjects != ["Fantasy"] }, "exploratory picks step outside")
        XCTAssertTrue(result.first?.reasons.contains("author:Ursula K. Le Guin") == true, "reasons are retained internally")
    }

    func testLowRatingsAndDNFsPushGenresAndAuthorsDown() {
        let books = [
            DiscoveryTasteBook(catalogID: "h1", title: "H1", author: "Historian 0", genres: ["History"], status: "read", rating: 1),
            DiscoveryTasteBook(catalogID: "h2", title: "H2", author: "Historian 1", genres: ["History"], status: "did-not-finish"),
            DiscoveryTasteBook(catalogID: "p1", title: "P1", author: "Poet 0", genres: ["Poetry"], status: "read", rating: 5),
            DiscoveryTasteBook(catalogID: "p2", title: "P2", author: "Poet 1", genres: ["Poetry"], status: "read", rating: 4.5),
        ]
        let result = DiscoveryRecommender.recommend(books: books, candidates: pool, seed: 1, limit: 40)
        let historyRanks = result.enumerated().filter { $0.element.item.id.hasPrefix("history") }.map(\.offset)
        XCTAssertFalse(result.prefix(5).contains { $0.item.id.hasPrefix("history") })
        XCTAssertTrue(historyRanks.allSatisfy { $0 > 10 } || historyRanks.isEmpty)
        XCTAssertFalse(result.contains { $0.personal && $0.item.author.hasPrefix("Historian 0") })
    }

    func testArchivedBooksAreNeverRecommended() {
        let books = [DiscoveryTasteBook(catalogID: "fantasy1", title: "x", author: "y", status: "read", rating: 5),
                     DiscoveryTasteBook(catalogID: nil, title: "Title fantasy2", author: "Fantasy Writer 2", status: "to-read"),
                     DiscoveryTasteBook(catalogID: "other", title: "z", author: "w", isbns: ["9780385550550"], status: "currently-reading")]
        var candidates = pool
        candidates.append(DiscoveryCandidate(item: item("isbn-match", isbns: ["978-0-385-55055-0"], subjects: ["Fantasy"]), collections: ["explore"]))
        let ids = Set(DiscoveryRecommender.recommend(books: books, candidates: candidates, seed: 1).map(\.item.id))
        XCTAssertFalse(ids.contains("fantasy1"), "read")
        XCTAssertFalse(ids.contains("fantasy2"), "TBR by title and author")
        XCTAssertFalse(ids.contains("isbn-match"), "matched by ISBN")
    }

    func testDiversityLimitsOneAuthorAndRankingIsDeterministic() {
        var candidates = pool
        for i in 0..<10 { candidates.append(candidate("prolific\(i)", author: "Prolific Fantasist", subjects: ["Fantasy"], popularity: 5000)) }
        let books = [DiscoveryTasteBook(catalogID: "own", title: "Own", author: "Prolific Fantasist", genres: ["Fantasy"],
                                        status: "read", rating: 5, favoriteRank: 0)]
        let result = DiscoveryRecommender.recommend(books: books, candidates: candidates, seed: 9, limit: 30)
        XCTAssertLessThanOrEqual(result.prefix(8).filter { $0.item.author == "Prolific Fantasist" }.count, 3)
        XCTAssertEqual(result.map(\.item.id),
                       DiscoveryRecommender.recommend(books: books, candidates: candidates, seed: 9, limit: 30).map(\.item.id))
    }

    func testChildrensBooksStayOutUnlessTheReaderReadsThem() {
        let kids = DiscoveryCandidate(item: item("kids", subjects: ["Juvenile fiction"], facet: "x"), collections: ["explore"])
        XCTAssertFalse(DiscoveryRecommender.recommend(books: [], candidates: pool + [kids], seed: 1).contains { $0.item.id == "kids" })
        let parent = [DiscoveryTasteBook(catalogID: "k1", title: "K", author: "A", genres: ["Children’s"], status: "read", rating: 5)]
        XCTAssertTrue(DiscoveryRecommender.recommend(books: parent, candidates: pool + [kids], seed: 1).contains { $0.item.id == "kids" })
    }

    func testSeedsAreStableAcrossProcesses() {
        XCTAssertEqual(DiscoverySeed.fnv(""), 0xcbf29ce484222325)
        XCTAssertEqual(DiscoverySeed.fnv("a"), 0xaf63dc4c8601ec8c, "FNV-1a, not Swift's per-process hash")
        XCTAssertEqual(DiscoverySeed.signature(["a", "b"]), DiscoverySeed.signature(["a", "b"]))
        XCTAssertNotEqual(DiscoverySeed.signature(["a", "b"]), DiscoverySeed.signature(["ab"]))
        let unit = DiscoverySeed.unit(42, "key")
        XCTAssertTrue((0..<1).contains(unit))
        XCTAssertEqual(unit, DiscoverySeed.unit(42, "key"))
    }
}

@MainActor
final class DiscoveryFeedWorkerTests: XCTestCase {
    func testExploreCachePreservesOrderAndInvalidatesForChangedSubjectsAndSeed() async throws {
        let worker = DiscoveryFeedWorker()
        let pool = (0..<40).map { item("book\($0)", author: "Author \($0)", subjects: ["Fantasy"], facet: "fantasy") }
        let expected = DiscoveryExploreOrder.order(pool, seed: 4)
        let first = try await worker.explore(pool, seed: 4)
        let cached = try await worker.explore(pool, seed: 4)
        XCTAssertEqual(first, expected)
        XCTAssertEqual(cached, expected)
        var changed = pool
        changed[0] = item("book0", subjects: ["Juvenile fiction"], facet: "fantasy")
        let updated = try await worker.explore(changed, seed: 4)
        XCTAssertFalse(updated.contains { $0.id == "book0" })
        let reseeded = try await worker.explore(pool, seed: 8)
        XCTAssertEqual(reseeded, DiscoveryExploreOrder.order(pool, seed: 8))
    }

    func testCancelledPreparationCannotReplaceCachedResults() async throws {
        let worker = DiscoveryFeedWorker()
        let pool = [item("one", subjects: ["History"])]
        let expected = try await worker.explore(pool, seed: 1)
        let cancelled = Task {
            try Task.checkCancellation()
            return try await worker.explore([item("other", subjects: ["Fantasy"])], seed: 2)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled work must throw") }
        catch is CancellationError { }
        let unchanged = try await worker.explore(pool, seed: 1)
        XCTAssertEqual(unchanged, expected)
    }

    func testTastePreservesRatingsFavoritesAndWithdrawalWithoutReviewHTMLWork() async throws {
        let worker = DiscoveryFeedWorker()
        let user = UUID()
        let book = Book(title: "Favorite", author: "Writer", isbn: "123", googleBooksVolumeId: "fav")
        book.storyGraphData = try JSONEncoder().encode(StoryGraphReadingData(sourceKey: "fixture", status: "read",
            dateAdded: nil, lastDateRead: nil, periods: [], readCount: 1, rating: 4.3,
            format: "", moods: [], pace: "", tags: [], owned: nil, originalFields: ["Review": "<p>Imported review</p>"]))
        book.cachedStatsClassification = try JSONEncoder().encode(BookCatalogService.ClassificationEvidence(
            categories: ["Fiction / Fantasy"], source: "google"))
        let favorite = ReaderFavorite(book: book)
        let profile = try JSONEncoder().encode(ReaderPublicContent(stats: .init(), sentence: "", favorites: [favorite]))
        let draft = try ReaderReviewDraft(userID: user, localBookID: book.id, content: .init())
        let imported = try await worker.taste([DiscoveryTasteInput(book: book, draft: draft)], profileData: profile)
        XCTAssertEqual(imported.first?.rating, 4.25)
        XCTAssertEqual(imported.first?.favoriteRank, 0)
        XCTAssertEqual(imported.first?.genres, ["Fantasy"])
        var saved = ReaderReviewContent(); saved.rating = 20
        draft.remoteData = try JSONEncoder().encode(RemoteReaderReview(workID: UUID(), bookID: UUID(), revision: 1, content: saved, deleted: false))
        let remote = try await worker.taste([DiscoveryTasteInput(book: book, draft: draft)], profileData: profile)
        XCTAssertEqual(remote.first?.rating, 5)
        draft.pendingData = try JSONEncoder().encode(ReaderReviewMutation(expectedUserID: user, operationID: UUID(), bookID: UUID(), expectedRevision: 1, content: saved, deleted: true))
        let withdrawn = try await worker.taste([DiscoveryTasteInput(book: book, draft: draft)], profileData: profile)
        XCTAssertNil(withdrawn.first?.rating, "Withdrawal must not resurrect an imported rating")
        book.cachedStatsClassification = try JSONEncoder().encode(BookCatalogService.ClassificationEvidence(categories: ["History"], source: "google"))
        let reclassified = try await worker.taste([DiscoveryTasteInput(book: book, draft: nil)], profileData: nil)
        XCTAssertEqual(reclassified.first?.genres, ["History"])
        let removed = try await worker.taste([], profileData: profile)
        XCTAssertEqual(removed.first?.catalogID, "fav", "A shelf-only favorite still informs taste")
        XCTAssertEqual(removed.first?.favoriteRank, 0)
    }

    func testWorkerRankingMatchesExistingRulesAndSkipsUnchangedInputs() async throws {
        let worker = DiscoveryFeedWorker()
        let items = (0..<50).map { item("book\($0)", author: "Writer \($0)", subjects: [$0.isMultiple(of: 2) ? "Fantasy" : "History"], facet: "explore") }
        let pools = [DiscoveryPool(collection: .explore, items: items, fetchedAt: Date(timeIntervalSince1970: 100))]
        let taste = [DiscoveryTasteBook(catalogID: "book0", title: "Title book0", author: "Writer 0", genres: ["Fantasy"], status: "read", rating: 5)]
        let result = try await worker.rank(taste: taste, pools: pools, seed: 9, previousSignature: nil, hasCachedResults: false)
        let ranking = try XCTUnwrap(result)
        let expected = DiscoveryRecommender.recommend(books: taste,
            candidates: items.map { DiscoveryCandidate(item: $0, collections: ["explore"]) }.sorted { $0.item.id < $1.item.id }, seed: 9)
        XCTAssertEqual(ranking.recommendations.map(\.item.id), expected.map(\.item.id))
        let skipped = try await worker.rank(taste: taste, pools: pools, seed: 9, previousSignature: ranking.signature, hasCachedResults: true)
        XCTAssertNil(skipped)
        let regenerated = try await worker.rank(taste: taste, pools: pools, seed: 9, previousSignature: ranking.signature, hasCachedResults: false)
        XCTAssertNotNil(regenerated, "Missing cached results must be rebuilt")
    }

    func testLargeLibraryAndDiscoveryWarmPreparation() async throws {
        let worker = DiscoveryFeedWorker()
        for count in [300, 1_000, 3_000] {
            let inputs = (0..<count).map { index in
                DiscoveryTasteInput(book: Book(title: "Own \(index)", author: "Author \(index)", isbn: "", googleBooksVolumeId: "own\(index)"), draft: nil)
            }
            let start = ContinuousClock.now
            let taste = try await worker.taste(inputs, profileData: nil)
            XCTAssertEqual(taste.count, count)
            let cached = try await worker.taste(inputs, profileData: nil)
            XCTAssertEqual(cached, taste)
            print("Discovery taste: \(count) books, cold+warm \(start.duration(to: .now))")
        }
        let pool = (0..<1_000).map { item("large\($0)", author: "Writer \($0)", subjects: ["Fantasy fiction", "Magic", "Adventure stories"], facet: "fantasy") }
        let first = try await worker.explore(pool, seed: 1)
        let warmStart = ContinuousClock.now
        let cached = try await worker.explore(pool, seed: 1)
        XCTAssertEqual(cached, first)
        XCTAssertEqual(cached.count, 1_000)
        print("Discovery Explore: 1000 cached entries \(warmStart.duration(to: .now))")
    }
}
