//
//  textualTests.swift
//  textualTests
//
//  Created by kiki o on 1/26/26.
//

import Foundation
import Testing
@testable import textual

@Suite(.serialized)
struct textualTests {
    @Test(arguments: ["s", "ab", "  s \n"])
    func shortQueriesDoNotRequestEitherProvider(query: String) async {
        for apiKey in [nil, "test-google-key"] as [String?] {
            let (service, session) = makeService(apiKey: apiKey) { _ in
                StubResponse(status: 422, json: #"{"detail":"Query too short"}"#)
            }
            defer { session.invalidateAndCancel() }
            do {
                _ = try await service.searchPage(query: query)
                Issue.record("An incomplete search must be rejected before reaching the catalog.")
            } catch BookCatalogService.ServiceError.queryTooShort {
                // Expected local validation, not a provider failure.
            } catch {
                Issue.record("Unexpected short-query error: \(error)")
            }
            #expect(BookServiceURLProtocol.state.requests.isEmpty)
        }
    }

    @Test func missingOrBlankKeySearchesOpenLibraryDirectly() async throws {
        for apiKey in [nil, "", " \n "] as [String?] {
            let (service, session) = makeService(apiKey: apiKey) { _ in
                StubResponse(status: 200, json: Self.openLibrarySearch)
            }
            defer { session.invalidateAndCancel() }

            let books = try await service.searchBooks(query: "A Wizard of Earthsea", startIndex: 20)
            let book = try #require(books.first)
            #expect(book.id == "openlibrary:OL66554W")
            #expect(book.volumeInfo?.title == "A Wizard of Earthsea")
            #expect(book.volumeInfo?.authors == ["Ursula K. Le Guin"])
            #expect(book.volumeInfo?.imageLinks?.thumbnail == "https://covers.openlibrary.org/b/id/12345-M.jpg")
            #expect(book.volumeInfo?.industryIdentifiers == nil)

            let requests = BookServiceURLProtocol.state.requests
            #expect(requests.count == 1)
            let request = try #require(requests.first)
            #expect(request.url?.host == "openlibrary.org")
            #expect(request.url?.path == "/search.json")
            #expect(queryValue("q", in: request) == "A Wizard of Earthsea")
            #expect(queryValue("limit", in: request) == "20")
            #expect(queryValue("offset", in: request) == "20")
            #expect(queryValue("fields", in: request) == "key,title,author_name,cover_i")
            #expect(queryValue("key", in: request) == nil)
        }
    }

    @Test(arguments: [400, 401, 403, 429, 503])
    func googleFailureFallsBackWithoutLeakingKey(status: Int) async throws {
        let (service, session) = makeService(apiKey: "test-google-key") { request in
            if request.url?.host == "www.googleapis.com" {
                return StubResponse(status: status, json: #"{"error":{"message":"Quota exceeded"}}"#)
            }
            return StubResponse(status: 200, json: Self.openLibrarySearch)
        }
        defer { session.invalidateAndCancel() }

        let books = try await service.searchBooks(query: "Earthsea")
        #expect(books.first?.id == "openlibrary:OL66554W")

        let requests = BookServiceURLProtocol.state.requests
        #expect(requests.count == 2)
        let googleRequest = try #require(requests.first)
        let fallbackRequest = try #require(requests.last)
        #expect(googleRequest.url?.host == "www.googleapis.com")
        #expect(queryValue("key", in: googleRequest) == "test-google-key")
        #expect(fallbackRequest.url?.host == "openlibrary.org")
        #expect(queryValue("key", in: fallbackRequest) == nil)
        #expect(fallbackRequest.url?.absoluteString.contains("test-google-key") == false)
    }

    @Test func googleSearchPreservesAuthorQueryAndAmpersand() async throws {
        let (service, session) = makeService(apiKey: "test-google-key") { _ in
            StubResponse(status: 200, json: #"{"items":[{"id":"google-book","volumeInfo":{"title":"A book"}}]}"#)
        }
        defer { session.invalidateAndCancel() }

        let query = "Ursula K. Le Guin & Octavia Butler + C++"
        let books = try await service.searchBooks(query: query)
        #expect(books.first?.id == "google-book")

        let requests = BookServiceURLProtocol.state.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.host == "www.googleapis.com")
        #expect(queryValue("q", in: request) == query)
        #expect(request.url?.absoluteString.contains("%2B") == true)
        #expect(queryValue("key", in: request) == "test-google-key")
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.contains { $0.name.contains("Butler") } == false)
    }

    @Test func bothProvidersFailWithAnErrorInsteadOfEmptyResults() async {
        let (service, session) = makeService(apiKey: "test-google-key") { request in
            let status = request.url?.host == "www.googleapis.com" ? 429 : 503
            return StubResponse(status: status, json: #"{"error":{"message":"Unavailable"}}"#)
        }
        defer { session.invalidateAndCancel() }

        var didThrow = false
        do {
            _ = try await service.searchBooks(query: "Earthsea")
        } catch {
            didThrow = true
        }
        #expect(didThrow)
        #expect(BookServiceURLProtocol.state.requests.count == 2)
    }

    @Test func openLibraryFailureWithoutAKeyStillThrows() async {
        let (service, session) = makeService(apiKey: nil) { _ in
            StubResponse(status: 503, json: #"{"error":"Unavailable"}"#)
        }
        defer { session.invalidateAndCancel() }

        var didThrow = false
        do {
            _ = try await service.searchBooks(query: "Earthsea")
        } catch {
            didThrow = true
        }
        #expect(didThrow)
        #expect(BookServiceURLProtocol.state.requests.count == 1)
    }

    @Test(arguments: [false, true])
    func openLibraryDetailsSupportBothDescriptionShapes(wrapped: Bool) async throws {
        let description = wrapped ? #"{"value":"An island wizard's journey."}"# : #""An island wizard's journey.""#
        let json = """
        {"key":"/works/OL66554W","title":"A Wizard of Earthsea","description":\(description),"subjects":["Fantasy","Wizards"]}
        """
        let (service, session) = makeService(apiKey: "test-google-key") { _ in
            StubResponse(status: 200, json: json)
        }
        defer { session.invalidateAndCancel() }

        let book = try await service.fetchVolume(id: "openlibrary:OL66554W")
        #expect(book.id == "openlibrary:OL66554W")
        #expect(book.volumeInfo?.title == "A Wizard of Earthsea")
        #expect(book.volumeInfo?.description == "An island wizard's journey.")
        #expect(book.volumeInfo?.categories == ["Fantasy", "Wizards"])

        let requests = BookServiceURLProtocol.state.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.host == "openlibrary.org")
        #expect(request.url?.path == "/works/OL66554W.json")
        #expect(queryValue("key", in: request) == nil)
    }

    @Test @MainActor
    func submittingNewQueryCancelsOlderDebouncedSearch() async throws {
        let (service, session) = makeService(apiKey: "test-google-key") { _ in
            StubResponse(status: 200, json: #"{"items":[{"id":"new-result","volumeInfo":{"title":"New result"}}]}"#)
        }
        defer { session.invalidateAndCancel() }
        let viewModel = AddBookViewModel(booksService: service)
        defer { viewModel.cancelSearch() }

        viewModel.searchText = "Old query"
        viewModel.searchTextDidChange()
        viewModel.searchText = "New query"
        viewModel.searchTextDidChange()
        await viewModel.performSearch()
        // Wait past the debounce so an uncancelled earlier task would be observed.
        try await Task.sleep(for: .milliseconds(750))

        let requests = BookServiceURLProtocol.state.requests
        #expect(requests.count == 1)
        #expect(queryValue("q", in: try #require(requests.first)) == "New query")
        #expect(viewModel.searchResults.first?.id == "new-result")
        #expect(viewModel.hasSearched)
        #expect(!viewModel.isSearching)
        #expect(viewModel.errorMessage == nil)
    }

    @Test(arguments: ["", "s", "ab", "  s  "]) @MainActor
    func clearingOrShorteningQueryCancelsPendingDebounce(query: String) async throws {
        let (service, session) = makeService(apiKey: "test-google-key") { _ in
            StubResponse(status: 200, json: #"{"items":[{"id":"stale-result","volumeInfo":{"title":"Stale result"}}]}"#)
        }
        defer { session.invalidateAndCancel() }
        let viewModel = AddBookViewModel(booksService: service)
        defer { viewModel.cancelSearch() }

        viewModel.searchText = "Old query"
        viewModel.searchTextDidChange()
        viewModel.searchText = query
        viewModel.searchTextDidChange()
        try await Task.sleep(for: .milliseconds(750))

        #expect(BookServiceURLProtocol.state.requests.isEmpty)
        #expect(viewModel.searchResults.isEmpty)
        #expect(!viewModel.hasSearched)
        #expect(!viewModel.isSearching)
        #expect(viewModel.errorMessage == nil)
    }

    @Test @MainActor
    func shortInputClearsResultsPaginationAndPriorErrors() async throws {
        let (service, session) = makeService(apiKey: nil) { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value
            return query == "Unavailable"
                ? StubResponse(status: 503, json: #"{"error":"Unavailable"}"#)
                : StubResponse(status: 200, json: Self.openLibraryPage(count: 20, firstID: 1, total: 40))
        }
        defer { session.invalidateAndCancel() }
        let viewModel = AddBookViewModel(booksService: service)
        defer { viewModel.cancelSearch() }

        viewModel.searchText = "  sun  "
        await viewModel.performSearch()
        #expect(viewModel.searchResults.count == 20)
        #expect(viewModel.canLoadMore)
        #expect(queryValue("q", in: try #require(BookServiceURLProtocol.state.requests.first)) == "sun")

        viewModel.searchText = " s "
        viewModel.searchTextDidChange()
        #expect(viewModel.isQueryTooShort)
        #expect(viewModel.searchResults.isEmpty)
        #expect(!viewModel.canLoadMore)
        #expect(!viewModel.hasSearched)
        #expect(!viewModel.isSearching)
        #expect(!viewModel.isLoadingMore)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.paginationErrorMessage == nil)
        await viewModel.performSearch()
        #expect(BookServiceURLProtocol.state.requests.count == 1)

        viewModel.searchText = "Unavailable"
        await viewModel.performSearch()
        #expect(viewModel.errorMessage != nil)
        viewModel.searchText = "ab"
        await viewModel.performSearch()
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.paginationErrorMessage == nil)
        #expect(!viewModel.hasSearched)
        #expect(!viewModel.isSearching)
        #expect(BookServiceURLProtocol.state.requests.count == 2)
    }

    @Test @MainActor
    func savedBookRemainsReadableWhenDetailsFail() async {
        let (service, session) = makeService(apiKey: nil) { _ in
            throw URLError(.notConnectedToInternet)
        }
        defer { session.invalidateAndCancel() }
        let book = Book(title: "Saved title", author: "Saved author", isbn: "", coverURL: "https://example.com/cover.jpg", googleBooksVolumeId: "openlibrary:OL66554W")
        let viewModel = BookDetailViewModel(booksService: service)
        await viewModel.fetchVolume(book: book)
        #expect(viewModel.volume?.volumeInfo?.title == "Saved title")
        #expect(viewModel.volume?.volumeInfo?.authors == ["Saved author"])
        #expect(viewModel.volume?.volumeInfo?.imageLinks?.thumbnail == book.coverURL)
        #expect(viewModel.errorMessage != nil)
        #expect(!viewModel.isLoading)
    }

    @Test @MainActor
    func fallbackDetailsKeepSavedAuthorAndCover() async {
        let (service, session) = makeService(apiKey: nil) { _ in
            StubResponse(status: 200, json: #"{"title":"A Wizard of Earthsea","description":"A young wizard's journey."}"#)
        }
        defer { session.invalidateAndCancel() }
        let book = Book(title: "A Wizard of Earthsea", author: "Ursula K. Le Guin", isbn: "", coverURL: "https://example.com/cover.jpg", googleBooksVolumeId: "openlibrary:OL66554W")
        let viewModel = BookDetailViewModel(booksService: service)
        await viewModel.fetchVolume(book: book)
        #expect(viewModel.volume?.volumeInfo?.authors == ["Ursula K. Le Guin"])
        #expect(viewModel.volume?.volumeInfo?.imageLinks?.thumbnail == book.coverURL)
        #expect(viewModel.volume?.volumeInfo?.description == "A young wizard's journey.")
        #expect(viewModel.errorMessage == nil)
    }

    @Test func openLibraryScopesUseDedicatedFieldsAndSeparateCacheEntries() async throws {
        let (service, session) = makeService(apiKey: nil) { _ in
            StubResponse(status: 200, json: Self.openLibrarySearch)
        }
        defer { session.invalidateAndCancel() }
        let scopes: [(BookCatalogService.SearchScope, String)] = [(.all, "q"), (.title, "title"), (.author, "author")]

        for (scope, field) in scopes {
            _ = try await service.searchPage(query: "Le Guin & Butler", scope: scope)
            let request = try #require(BookServiceURLProtocol.state.requests.last)
            #expect(queryValue(field, in: request) == "Le Guin & Butler")
            for otherField in ["q", "title", "author"] where otherField != field {
                #expect(queryValue(otherField, in: request) == nil)
            }
        }
        #expect(BookServiceURLProtocol.state.requests.count == 3)
    }

    @Test func googleScopesQuoteAndEscapeScopedQueries() async throws {
        let (service, session) = makeService(apiKey: "test-google-key") { _ in
            StubResponse(status: 200, json: Self.googleSearch)
        }
        defer { session.invalidateAndCancel() }
        let query = "Dune & \"Sand\""
        let cases: [(BookCatalogService.SearchScope, String)] = [
            (.all, query),
            (.title, "intitle:\"Dune & \\\"Sand\\\"\""),
            (.author, "inauthor:\"Dune & \\\"Sand\\\"\"")
        ]
        for (scope, expectedQuery) in cases {
            _ = try await service.searchPage(query: query, scope: scope)
            let request = try #require(BookServiceURLProtocol.state.requests.last)
            #expect(queryValue("q", in: request) == expectedQuery)
            #expect(queryValue("maxResults", in: request) == "20")
        }
        #expect(BookServiceURLProtocol.state.requests.count == 3)
    }

    @Test func repeatingSearchUsesCacheForEitherProvider() async throws {
        for key in [nil, "test-google-key"] as [String?] {
            let (service, session) = makeService(apiKey: key) { request in
                StubResponse(status: 200, json: request.url?.host == "openlibrary.org" ? Self.openLibrarySearch : Self.googleSearch)
            }
            defer { session.invalidateAndCancel() }

            let first = try await service.searchPage(query: "Earthsea", scope: .author)
            let second = try await service.searchPage(query: "Earthsea", scope: .author)
            #expect(first.items.map(\.id) == second.items.map(\.id))
            #expect(first.provider == second.provider)
            #expect(BookServiceURLProtocol.state.requests.count == 1)
        }
    }

    @Test func openLibraryPaginationKeepsProviderAndStopsAtTotal() async throws {
        let (service, session) = makeService(apiKey: nil) { request in
            let offset = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "offset" })?.value
            return StubResponse(status: 200, json: offset == "20"
                ? Self.openLibraryPage(count: 3, firstID: 21, total: 23)
                : Self.openLibraryPage(count: 20, firstID: 1, total: 23))
        }
        defer { session.invalidateAndCancel() }

        let first = try await service.searchPage(query: "Fantasy")
        #expect(first.items.count == 20)
        #expect(first.provider == .openLibrary)
        #expect(first.nextOffset == 20)
        let nextOffset = try #require(first.nextOffset)
        let second = try await service.searchPage(query: "Fantasy", startIndex: nextOffset, provider: first.provider)
        #expect(second.items.count == 3)
        #expect(second.items.first?.id == "openlibrary:OL21W")
        #expect(second.provider == .openLibrary)
        #expect(second.nextOffset == nil)
        #expect(BookServiceURLProtocol.state.requests.count == 2)
    }

    @Test func fullOpenLibraryPageWithoutTotalOffersAnotherPage() async throws {
        let (service, session) = makeService(apiKey: nil) { _ in
            StubResponse(status: 200, json: Self.openLibraryPage(count: 20, firstID: 1, total: nil))
        }
        defer { session.invalidateAndCancel() }
        let page = try await service.searchPage(query: "Fantasy")
        #expect(page.nextOffset == 20)
        #expect(page.provider == .openLibrary)
    }

    @Test func googlePaginationKeepsProviderAndStopsAtTotal() async throws {
        let (service, session) = makeService(apiKey: "test-google-key") { request in
            let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            if queryItems?.first(where: { $0.name == "q" })?.value == "Partial page" {
                return StubResponse(status: 200, json: Self.googlePage(count: 12, firstID: 1, total: 100))
            }
            let offset = queryItems?.first(where: { $0.name == "startIndex" })?.value
            return StubResponse(status: 200, json: offset == "20"
                ? Self.googlePage(count: 2, firstID: 21, total: 22)
                : Self.googlePage(count: 20, firstID: 1, total: 22))
        }
        defer { session.invalidateAndCancel() }
        let first = try await service.searchPage(query: "Fantasy")
        #expect(first.provider == .google)
        #expect(first.nextOffset == 20)
        let second = try await service.searchPage(query: "Fantasy", startIndex: try #require(first.nextOffset), provider: first.provider)
        #expect(second.items.count == 2)
        #expect(second.provider == .google)
        #expect(second.items.first?.id == "google-21")
        #expect(second.nextOffset == nil)
        #expect(BookServiceURLProtocol.state.requests.count == 2)

        // A known total takes precedence over the full-page heuristic.
        let partial = try await service.searchPage(query: "Partial page")
        #expect(partial.items.count == 12)
        #expect(partial.nextOffset == 12)
        #expect(partial.provider == .google)
        #expect(BookServiceURLProtocol.state.requests.count == 3)
    }

    @Test func googleFailureCooldownSkipsGoogleForFollowingQuery() async throws {
        let (service, session) = makeService(apiKey: "test-google-key") { request in
            if request.url?.host == "www.googleapis.com" {
                return StubResponse(status: 429, json: #"{"error":{"message":"Quota exceeded"}}"#)
            }
            return StubResponse(status: 200, json: Self.openLibrarySearch)
        }
        defer { session.invalidateAndCancel() }
        let first = try await service.searchPage(query: "Earthsea")
        let second = try await service.searchPage(query: "The Dispossessed")
        #expect(first.provider == .openLibrary)
        #expect(second.provider == .openLibrary)
        let requests = BookServiceURLProtocol.state.requests
        #expect(requests.count == 3)
        #expect(requests.filter { $0.url?.host == "www.googleapis.com" }.count == 1)
    }

    @Test func failedPinnedGooglePageThrowsWithoutMixingCatalogs() async throws {
        let (service, session) = makeService(apiKey: "test-google-key") { request in
            if request.url?.host == "openlibrary.org" {
                return StubResponse(status: 200, json: Self.openLibrarySearch)
            }
            let offset = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "startIndex" })?.value
            return offset == "20"
                ? StubResponse(status: 429, json: #"{"error":{"message":"Quota exceeded"}}"#)
                : StubResponse(status: 200, json: Self.googlePage(count: 20, firstID: 1, total: 40))
        }
        defer { session.invalidateAndCancel() }
        let first = try await service.searchPage(query: "Fantasy")
        var didThrow = false
        do {
            _ = try await service.searchPage(query: "Fantasy", startIndex: try #require(first.nextOffset), provider: first.provider)
        } catch {
            didThrow = true
        }
        #expect(didThrow)
        let requests = BookServiceURLProtocol.state.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.url?.host == "www.googleapis.com" })

        // The failed page stays on Google, but its quota failure also cools down
        // Google for the next independent search.
        let nextQuery = try await service.searchPage(query: "Earthsea")
        #expect(nextQuery.provider == .openLibrary)
        let requestsAfterNewQuery = BookServiceURLProtocol.state.requests
        #expect(requestsAfterNewQuery.count == 3)
        #expect(requestsAfterNewQuery.last?.url?.host == "openlibrary.org")
        #expect(requestsAfterNewQuery.filter { $0.url?.host == "www.googleapis.com" }.count == 2)
    }

    @Test func repeatedDetailsUseCacheForEitherProvider() async throws {
        for id in ["openlibrary:OL66554W", "google-book"] {
            let (service, session) = makeService(apiKey: "test-google-key") { request in
                StubResponse(status: 200, json: request.url?.host == "openlibrary.org"
                    ? #"{"title":"Earthsea","description":"A young wizard's journey."}"#
                    : #"{"id":"google-book","volumeInfo":{"title":"Earthsea","description":"A young wizard's journey."}}"#)
            }
            defer { session.invalidateAndCancel() }
            let first = try await service.fetchVolume(id: id)
            let second = try await service.fetchVolume(id: id)
            #expect(first.id == second.id)
            #expect(second.volumeInfo?.description == "A young wizard's journey.")
            #expect(BookServiceURLProtocol.state.requests.count == 1)
        }
    }

    @Test @MainActor
    func savedCatalogDetailsSurviveAViewModelAndServiceReload() async {
        let (service, session) = makeService(apiKey: nil) { _ in
            StubResponse(status: 200, json: #"{"title":"Earthsea","description":"A saved description."}"#)
        }
        defer { session.invalidateAndCancel() }
        let book = Book(title: "Earthsea", author: "Ursula K. Le Guin", isbn: "", googleBooksVolumeId: "openlibrary:OL66554W")
        let initialViewModel = BookDetailViewModel(booksService: service)
        await initialViewModel.fetchVolume(book: book)
        #expect(book.cachedCatalogMetadata != nil)
        #expect(book.catalogMetadataUpdatedAt != nil)

        let (offlineService, offlineSession) = makeService(apiKey: nil) { _ in
            throw URLError(.notConnectedToInternet)
        }
        defer { offlineSession.invalidateAndCancel() }
        let reopenedViewModel = BookDetailViewModel(booksService: offlineService)
        await reopenedViewModel.fetchVolume(book: book)
        #expect(reopenedViewModel.volume?.volumeInfo?.description == "A saved description.")
        #expect(reopenedViewModel.errorMessage == nil)
        #expect(BookServiceURLProtocol.state.requests.isEmpty)
    }

    @Test @MainActor
    func loadingMoreAppendsUniqueBooksAndKeepsExistingResults() async throws {
        let (service, session) = makeService(apiKey: nil) { request in
            let offset = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "offset" })?.value
            return StubResponse(status: 200, json: offset == "20"
                ? Self.openLibraryPage(count: 3, firstID: 20, total: 23)
                : Self.openLibraryPage(count: 20, firstID: 1, total: 23))
        }
        defer { session.invalidateAndCancel() }
        let viewModel = AddBookViewModel(booksService: service)
        defer { viewModel.cancelSearch() }
        viewModel.searchText = "Fantasy"
        await viewModel.performSearch()
        #expect(viewModel.canLoadMore)
        await viewModel.performLoadMore()
        #expect(viewModel.searchResults.count == 22)
        #expect(viewModel.searchResults.first?.id == "openlibrary:OL1W")
        #expect(viewModel.searchResults.last?.id == "openlibrary:OL22W")
        #expect(!viewModel.canLoadMore)
        #expect(!viewModel.isLoadingMore)
        #expect(viewModel.paginationErrorMessage == nil)
    }

    @Test @MainActor
    func paginationFailureKeepsLoadedBooksAndAllowsRetry() async {
        let (service, session) = makeService(apiKey: "test-google-key") { request in
            let offset = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "startIndex" })?.value
            return offset == "20"
                ? StubResponse(status: 503, json: #"{"error":{"message":"Unavailable"}}"#)
                : StubResponse(status: 200, json: Self.googlePage(count: 20, firstID: 1, total: 40))
        }
        defer { session.invalidateAndCancel() }
        let viewModel = AddBookViewModel(booksService: service)
        defer { viewModel.cancelSearch() }
        viewModel.searchText = "Fantasy"
        await viewModel.performSearch()
        await viewModel.performLoadMore()
        #expect(viewModel.searchResults.count == 20)
        #expect(viewModel.searchResults.first?.id == "google-1")
        #expect(viewModel.canLoadMore)
        #expect(!viewModel.isLoadingMore)
        #expect(viewModel.paginationErrorMessage != nil)
        #expect(viewModel.errorMessage == nil)
        #expect(BookServiceURLProtocol.state.requests.allSatisfy { $0.url?.host == "www.googleapis.com" })
    }

    private static func openLibraryPage(count: Int, firstID: Int, total: Int?) -> String {
        let documents = (firstID..<(firstID + count)).map { id in
            "{\"key\":\"/works/OL\(id)W\",\"title\":\"Book \(id)\",\"author_name\":[\"Author\"]}"
        }.joined(separator: ",")
        let totalField = total.map { ",\"numFound\":\($0)" } ?? ""
        return "{\"docs\":[\(documents)]\(totalField)}"
    }

    private static func googlePage(count: Int, firstID: Int, total: Int) -> String {
        let items = (firstID..<(firstID + count)).map { id in
            "{\"id\":\"google-\(id)\",\"volumeInfo\":{\"title\":\"Book \(id)\"}}"
        }.joined(separator: ",")
        return "{\"items\":[\(items)],\"totalItems\":\(total)}"
    }

    private static let googleSearch = #"{"totalItems":1,"items":[{"id":"google-book","volumeInfo":{"title":"Earthsea"}}]}"#

    private func makeService(
        apiKey: String?,
        handler: @escaping (URLRequest) throws -> StubResponse
    ) -> (BookCatalogService, URLSession) {
        BookServiceURLProtocol.state.configure(handler: handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BookServiceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return (BookCatalogService(session: session, apiKey: apiKey, minimumRequestInterval: 0), session)
    }

    private func queryValue(_ name: String, in request: URLRequest) -> String? {
        guard let url = request.url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == name })?.value
    }

    private static let openLibrarySearch = #"""
    {"docs":[{"key":"/works/OL66554W","title":"A Wizard of Earthsea","author_name":["Ursula K. Le Guin"],"cover_i":12345}]}
    """#
}

private struct StubResponse {
    let status: Int
    let json: String
}

private final class BookServiceURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = StubState()

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let stub = try Self.state.response(for: request)
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: stub.status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                  ) else {
                throw URLError(.badServerResponse)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(stub.json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class StubState: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((URLRequest) throws -> StubResponse)?
    private var recordedRequests: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func configure(handler: @escaping (URLRequest) throws -> StubResponse) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
        recordedRequests = []
    }

    func response(for request: URLRequest) throws -> StubResponse {
        lock.lock()
        recordedRequests.append(request)
        let currentHandler = handler
        lock.unlock()
        guard let currentHandler else { throw URLError(.resourceUnavailable) }
        return try currentHandler(request)
    }
}
