import Foundation
import Observation
import SwiftData
import Supabase

enum DiscoveryRefreshError: Error { case empty }

protocol DiscoveryTransport: Sendable {
    func page(_ collection: DiscoveryCollection, offset: Int, limit: Int) async throws -> DiscoveryPage
}

/// Network work stays off the main actor; only immutable values cross back.
actor SupabaseDiscoveryTransport: DiscoveryTransport {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func page(_ collection: DiscoveryCollection, offset: Int, limit: Int) async throws -> DiscoveryPage {
        struct Parameters: Encodable { let p_collection: String; let p_offset: Int; let p_limit: Int }
        let response = try await client.rpc("textual_read_discovery", params: Parameters(
            p_collection: collection.rawValue, p_offset: offset, p_limit: limit)).execute()
        return try JSONDecoder().decode(DiscoveryPage.self, from: response.data)
    }
}

/// Local-first discovery cache. Views read SwiftData immediately; refreshes run
/// quietly, are throttled per collection, and back off after failures. A failed
/// refresh never clears cached books, and nothing is invented to fill a gap.
@MainActor
@Observable
final class DiscoveryRepository {
    private(set) var refreshing: Set<DiscoveryCollection> = []
    /// Collections whose latest refresh failed; used only when no cache exists.
    private(set) var failed: Set<DiscoveryCollection> = []
    /// Increments whenever a collection is rewritten, so dependents can re-rank.
    private(set) var revision = 0

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let transport: any DiscoveryTransport
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var active = true
    static let pageSize = 200
    static let maximumPages = 5

    init(context: ModelContext, transport: any DiscoveryTransport, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.transport = transport
        self.now = now
    }

    func stop() { active = false }

    /// Refreshes every server collection that is stale (or all, when forced).
    func refreshAll(force: Bool = false) async {
        await withTaskGroup(of: Void.self) { group in
            for collection in DiscoveryCollection.remote {
                group.addTask { await self.refresh(collection, force: force) }
            }
        }
    }

    func refresh(_ collection: DiscoveryCollection, force: Bool = false) async {
        guard active, DiscoveryCollection.remote.contains(collection), !refreshing.contains(collection) else { return }
        let state = self.state(collection)
        let current = now()
        if !force {
            if let fetched = state?.fetchedAt, current.timeIntervalSince(fetched) < collection.freshness { return }
            if let failure = state?.lastFailureAt,
               current.timeIntervalSince(failure) < Self.backoff(failures: state?.failureCount ?? 0) { return }
        }
        refreshing.insert(collection)
        defer { refreshing.remove(collection) }
        do {
            var rows: [DiscoveryPage.Row] = []
            var refreshedAt: String?
            var attribution: [String] = []
            for page in 0..<Self.maximumPages {
                let result = try await transport.page(collection, offset: page * Self.pageSize, limit: Self.pageSize)
                try Task.checkCancellation()
                refreshedAt = refreshedAt ?? result.refreshedAt
                attribution = Array(Set(attribution + result.attribution)).sorted()
                rows += result.books
                if result.books.count < Self.pageSize || rows.count >= result.total { break }
            }
            guard active else { return }
            let items = rows.compactMap(\.item)
            // A collection that hasn't been filled yet is a retry, not a fresh empty result.
            guard !items.isEmpty else { throw DiscoveryRefreshError.empty }
            try replace(collection, with: items)
            let saved = self.state(collection) ?? insertState(collection)
            saved.fetchedAt = now()
            saved.serverRefreshedAt = refreshedAt.flatMap(DiscoveryDate.parse)
            saved.attribution = attribution
            saved.lastFailureAt = nil
            saved.failureCount = 0
            try context.save()
            failed.remove(collection)
            revision += 1
        } catch {
            guard active, !(error is CancellationError) else { return }
            context.rollback()
            let saved = self.state(collection) ?? insertState(collection)
            saved.lastFailureAt = now()
            saved.failureCount += 1
            try? context.save()
            failed.insert(collection)
        }
    }

    /// Writes the For You ranking (or author candidates) produced on this device.
    func store(_ items: [(item: DiscoverItem, reasons: [String])], in collection: DiscoveryCollection,
               signature: String) throws {
        guard active, !DiscoveryCollection.remote.contains(collection) else { return }
        try replace(collection, with: items.map(\.item), reasons: items.map(\.reasons))
        let saved = state(collection) ?? insertState(collection)
        saved.fetchedAt = now()
        saved.inputSignature = signature
        try context.save()
        revision += 1
    }

    func state(_ collection: DiscoveryCollection) -> DiscoveryCollectionState? {
        let name = collection.rawValue
        var descriptor = FetchDescriptor<DiscoveryCollectionState>(predicate: #Predicate { $0.collection == name })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Cached rows in collection order, without provider content past its cache limit.
    func items(_ collection: DiscoveryCollection) -> [DiscoverItem] {
        let name = collection.rawValue
        let descriptor = FetchDescriptor<DiscoveryCacheEntry>(predicate: #Predicate { $0.collection == name },
                                                              sortBy: [SortDescriptor(\.position)])
        let date = now()
        return ((try? context.fetch(descriptor)) ?? []).map(\.item).filter { $0.isVisible(at: date) }
    }

    func entries(_ collection: DiscoveryCollection) -> [DiscoveryCacheEntry] {
        let name = collection.rawValue
        return (try? context.fetch(FetchDescriptor<DiscoveryCacheEntry>(
            predicate: #Predicate { $0.collection == name }, sortBy: [SortDescriptor(\.position)]))) ?? []
    }

    func attribution(_ collection: DiscoveryCollection) -> [String] { state(collection)?.attribution ?? [] }

    /// Exponential backoff from one minute, capped at one hour.
    static func backoff(failures: Int) -> TimeInterval {
        min(3600, 60 * pow(2, Double(max(0, min(failures, 12)) - 1)))
    }

    /// Updates rows in place (unique keys make delete-then-insert unsafe) and removes leftovers.
    private func replace(_ collection: DiscoveryCollection, with items: [DiscoverItem], reasons: [[String]] = []) throws {
        var existing = Dictionary(entries(collection).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var position = 0
        var seen = Set<String>()
        for (index, item) in items.enumerated() where seen.insert(item.catalogID).inserted {
            let why = index < reasons.count ? reasons[index] : []
            if let entry = existing.removeValue(forKey: DiscoveryCacheEntry.key(collection, item.catalogID)) {
                entry.update(position: position, item: item, reasons: why)
            } else {
                context.insert(DiscoveryCacheEntry(collection: collection, position: position, item: item, reasons: why))
            }
            position += 1
        }
        for entry in existing.values { context.delete(entry) }
    }

    private func insertState(_ collection: DiscoveryCollection) -> DiscoveryCollectionState {
        let state = DiscoveryCollectionState(collection: collection)
        context.insert(state)
        return state
    }
}
