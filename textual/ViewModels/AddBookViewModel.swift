//
//  AddBookViewModel.swift
//  textual
//
//  Created by kiki o on 1/26/26.
//

import Foundation
import Observation

@MainActor
@Observable
final class AddBookViewModel {
    var searchText = ""
    var searchScope: BookCatalogService.SearchScope = .all
    var searchResults: [BookCatalogService.BookItem] = []
    var isSearching = false
    var isLoadingMore = false
    var hasSearched = false
    var errorMessage: String?
    var paginationErrorMessage: String?

    @ObservationIgnored private let booksService: BookCatalogService
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var pageTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = UUID()
    private var nextOffset: Int?
    private var resultProvider: BookCatalogService.Provider?
    private var resultQuery = ""
    private var resultScope: BookCatalogService.SearchScope = .all

    init(booksService: BookCatalogService = .shared) {
        self.booksService = booksService
    }

    var searchPlaceholder: String {
        switch searchScope {
        case .all: return "Search by title or author"
        case .title: return "Search by book title"
        case .author: return "Search by author name"
        }
    }

    var canLoadMore: Bool {
        nextOffset != nil && !isSearching
            && resultQuery == searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            && resultScope == searchScope
    }

    var isQueryTooShort: Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !query.isEmpty && query.count < BookCatalogService.minimumSearchQueryLength
    }

    func searchTextDidChange() {
        scheduleSearch(debounce: true)
    }

    func searchScopeDidChange() {
        scheduleSearch(debounce: false)
    }

    func submitSearch() {
        scheduleSearch(debounce: false)
    }

    func clearSearch() {
        searchText = ""
        scheduleSearch(debounce: false)
    }

    /// Runs immediately and allows callers to await the current search.
    func performSearch() async {
        submitSearch()
        await searchTask?.value
    }

    func cancelSearch() {
        searchTask?.cancel()
        pageTask?.cancel()
        searchTask = nil
        pageTask = nil
        // Invalidate results even if a network operation finishes after cancellation.
        searchGeneration = UUID()
        isSearching = false
        isLoadingMore = false
    }

    private func scheduleSearch(debounce: Bool) {
        cancelSearch()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = searchScope
        errorMessage = nil
        paginationErrorMessage = nil
        hasSearched = false
        nextOffset = nil
        resultProvider = nil
        guard query.count >= BookCatalogService.minimumSearchQueryLength else {
            searchResults = []
            resultQuery = ""
            resultScope = scope
            return
        }

        // Keep the previous rows visible until the replacement page arrives.
        isSearching = true
        let generation = searchGeneration
        searchTask = Task { [weak self] in
            do {
                if debounce {
                    try await Task.sleep(for: .milliseconds(300))
                }
                try Task.checkCancellation()
            } catch {
                return
            }
            await self?.search(query: query, scope: scope, generation: generation)
        }
    }

    private func search(query: String, scope: BookCatalogService.SearchScope, generation: UUID) async {
        do {
            let page = try await booksService.searchPage(query: query, scope: scope)
            try Task.checkCancellation()
            guard generation == searchGeneration else { return }
            searchResults = page.items
            nextOffset = page.nextOffset
            resultProvider = page.provider
            resultQuery = query
            resultScope = scope
        } catch {
            guard generation == searchGeneration else { return }
            if isCancellation(error) {
                isSearching = false
                searchTask = nil
                return
            }
            errorMessage = searchErrorMessage(for: error)
            searchResults = []
        }

        hasSearched = true
        isSearching = false
        searchTask = nil
    }

    func loadMore() {
        guard canLoadMore, !isLoadingMore, let offset = nextOffset, let provider = resultProvider else { return }
        let query = resultQuery
        let scope = resultScope
        let generation = searchGeneration
        isLoadingMore = true
        paginationErrorMessage = nil
        pageTask = Task { [weak self] in
            await self?.fetchNextPage(query: query, scope: scope, offset: offset, provider: provider, generation: generation)
        }
    }

    func performLoadMore() async {
        loadMore()
        await pageTask?.value
    }

    private func fetchNextPage(
        query: String,
        scope: BookCatalogService.SearchScope,
        offset: Int,
        provider: BookCatalogService.Provider,
        generation: UUID
    ) async {
        do {
            let page = try await booksService.searchPage(query: query, scope: scope, startIndex: offset, provider: provider)
            try Task.checkCancellation()
            guard generation == searchGeneration else { return }
            var knownIDs = Set(searchResults.compactMap(\.id))
            searchResults.append(contentsOf: page.items.filter { item in
                guard let id = item.id else { return false }
                return knownIDs.insert(id).inserted
            })
            nextOffset = page.nextOffset
        } catch {
            guard generation == searchGeneration else { return }
            if !isCancellation(error) {
                paginationErrorMessage = searchErrorMessage(for: error)
            }
        }
        isLoadingMore = false
        pageTask = nil
    }

    private func isCancellation(_ error: Error) -> Bool {
        Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private func searchErrorMessage(for error: Error) -> String {
        if let networkError = error as? URLError {
            switch networkError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "You appear to be offline. Check your connection and try again."
            case .timedOut:
                return "The book catalog took too long to respond. Please try again."
            default:
                break
            }
        }
        return (error as? LocalizedError)?.errorDescription
            ?? "We couldn’t search for books right now. Please try again."
    }

    func extractTitle(from item: BookCatalogService.BookItem) -> String {
        item.volumeInfo?.title ?? "No Title"
    }
    
    func extractISBN(from item: BookCatalogService.BookItem) -> String {
        guard let identifiers = item.volumeInfo?.industryIdentifiers else {
            // Fallback to item ID if available
            return item.id ?? ""
        }
        
        // Prefer ISBN_13, fallback to ISBN_10
        if let isbn13 = identifiers.first(where: { $0.type == "ISBN_13" }),
           let identifier = isbn13.identifier {
            return identifier
        }
        
        if let isbn10 = identifiers.first(where: { $0.type == "ISBN_10" }),
           let identifier = isbn10.identifier {
            return identifier
        }
        
        // Final fallback to item ID
        return item.id ?? ""
    }
    
    func extractCoverURL(from item: BookCatalogService.BookItem) -> String {
        let urlString = item.volumeInfo?.imageLinks?.thumbnail ?? item.volumeInfo?.imageLinks?.smallThumbnail
        return BookCatalogService.secureImageURL(urlString)
    }
    
    func extractAuthor(from item: BookCatalogService.BookItem) -> String {
        guard let authors = item.volumeInfo?.authors, !authors.isEmpty else {
            return "Unknown Author"
        }
        return authors.joined(separator: ", ")
    }
}
