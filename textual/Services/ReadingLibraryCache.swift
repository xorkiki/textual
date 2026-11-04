import Foundation
import SwiftData
import SwiftUI
import Observation
import os

/// Copy only values across actors. SwiftData models stay on their owning context.
struct ReadingBookInput: Equatable, Sendable {
    let id: UUID
    let title: String
    let author: String
    let isbn: String
    let readingData: Data?
    let metadata: Data?
    let classification: Data?

    @MainActor init(_ book: Book) {
        id = book.id; title = book.title; author = book.author; isbn = book.isbn
        readingData = book.storyGraphData
        metadata = book.cachedCatalogMetadata
        classification = book.cachedStatsClassification
    }
}

struct ReadingBookSnapshot: Sendable {
    let input: ReadingBookInput
    let reading: StoryGraphReadingData?
    let genres: Set<String>
    let pages: Int?
    let pageEstimate: CatalogPageEstimate
    var statsPages: Int { pages ?? pageEstimate.value }
    var pageEstimateReason: String? { pages == nil ? pageEstimate.reason : nil }
    let pace: ReviewStatsResolver.Value<ReaderReviewContent.Pace>
    let paceGuess: CatalogPaceEstimate
    var paceEstimateReason: String? { pace.source == .estimated ? paceGuess.reason : nil }
    let kind: BookFictionKind?
    let moods: ReviewStatsResolver.Value<[String]>?
    let catalogMoods: CatalogMoodEstimate
    let guess: CatalogStatsGuess
    var statsKind: BookFictionKind { kind ?? guess.kind }
    var statsGenres: Set<String> { genres.isEmpty ? guess.genres : genres }
    var moodEstimateReason: String? { (moods?.source == .catalog || moods?.source == .estimated) ? guess.moodReason : nil }
    var id: UUID { input.id }

    init(_ input: ReadingBookInput) {
        self.input = input
        let decoder = JSONDecoder()
        reading = input.readingData.flatMap { try? decoder.decode(StoryGraphReadingData.self, from: $0) }
        let metadata = input.metadata.flatMap { try? decoder.decode(BookCatalogService.BookItem.self, from: $0) }
        let evidence = input.classification.flatMap { try? decoder.decode(BookCatalogService.ClassificationEvidence.self, from: $0) }
        let evidenceCategories = evidence.map { $0.categories + ($0.openLibraryCategories ?? []) } ?? []
        let categories = evidenceCategories.isEmpty ? (metadata?.volumeInfo?.catalogCategories ?? []) : evidenceCategories
        catalogMoods = CatalogMoodEstimate(categories: categories)
        let knownGenres = evidence?.genres ?? []
        genres = knownGenres.isEmpty
            ? GenreTaxonomy.normalized(metadata?.volumeInfo?.catalogCategories ?? [], isOpenLibrary: metadata?.id?.hasPrefix("openlibrary:") == true)
            : knownGenres
        if let count = evidence?.editionPages, count > 0,
           let isbn = StoryGraphImporter.normalizedISBN(input.isbn), evidence?.editionISBN == isbn {
            pages = count
        } else {
            pages = metadata?.volumeInfo?.pageCount.flatMap { $0 > 0 ? $0 : nil }
        }
        kind = evidence?.fictionKind ?? BookFictionKind.classify(metadata?.volumeInfo?.catalogCategories ?? [])
        let context = (evidence?.context ?? []) + (metadata.map(BookCatalogService.classificationContext) ?? [])
        guess = CatalogStatsGuess(title: input.title, categories: categories, context: context,
                                  knownKind: kind, knownGenres: genres, directMoods: catalogMoods)
        moods = ReviewStatsResolver.moods(personal: nil, imported: reading?.moods ?? [], community: nil,
                                         catalogCategories: categories)
            ?? .init(value: guess.moods, source: .estimated)
        paceGuess = CatalogPaceEstimate(categories: categories, context: context, genres: genres)
        pace = ReviewStatsResolver.pace(personal: nil, imported: reading?.pace, community: nil, estimate: paceGuess)!
        pageEstimate = CatalogPageEstimate(workPageCounts: evidence?.workPageCounts ?? [], categories: categories,
                                           kind: kind ?? guess.kind, genres: genres)
    }
}

struct ReadingLibrarySnapshot: Sendable {
    var revision = 0
    var entries: [ReadingBookSnapshot] = []
    var profile = ReaderPersonality.summarize([], favorites: [])
    var years: [Int] = []
    var archive = ArchiveSnapshot(entries: [])
    var currentlyReading: Set<UUID> = []
    var queue: [UUID] = []
}

/// One worker/cache per signed-in account, never a process-wide cache of private data.
actor ReadingLibraryWorker {
    private let log = OSLog(subsystem: "kiki.textual", category: "ReadingPerformance")
    private var decoded: [UUID: ReadingBookSnapshot] = [:]
    private var revision = 0
    private var statsRevision = -1
    private var statsCache: [ReadingStatsFilter: UserReadingStats] = [:]

    func prepare(_ inputs: [ReadingBookInput]) throws -> ReadingLibrarySnapshot {
        let signpost = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "Prepare reading library", signpostID: signpost)
        defer { os_signpost(.end, log: log, name: "Prepare reading library", signpostID: signpost) }
        var next: [UUID: ReadingBookSnapshot] = [:]
        var entries: [ReadingBookSnapshot] = []
        for input in inputs {
            try Task.checkCancellation()
            let entry = decoded[input.id].flatMap { $0.input == input ? $0 : nil } ?? ReadingBookSnapshot(input)
            next[input.id] = entry
            entries.append(entry)
        }
        let evidence = entries.compactMap { entry -> ReaderPersonality.Evidence? in
            guard let reading = entry.reading else { return nil }
            let count = ReadingStatsFilter.completedCount(reading)
            return count > 0 ? .init(completedReads: count, genres: entry.genres, moods: reading.moods, pace: reading.pace) : nil
        }
        let dates = entries.compactMap(\.reading).flatMap {
            ReadingStatsFilter.completedDates($0) + [ReadingStatsFilter.date($0.dateAdded)].compactMap { $0 }
        }
        let years = Set(dates.map { Calendar(identifier: .gregorian).component(.year, from: $0) }).sorted(by: >)
        try Task.checkCancellation()
        decoded = next
        revision += 1
        return ReadingLibrarySnapshot(revision: revision, entries: entries,
            profile: ReaderPersonality.summarize(evidence, favorites: []), years: years,
            archive: ArchiveSnapshot(entries: entries),
            currentlyReading: Set(entries.filter { $0.reading?.status == "currently-reading" }.map(\.id)),
            queue: entries.filter { entry in
                guard entry.reading?.status != "currently-reading", entry.reading?.upNextExcluded != true else { return false }
                return entry.reading?.upNextPosition != nil || (entry.reading?.tags.contains { $0.lowercased().filter(\.isLetter) == "upnext" } ?? false)
            }.sorted {
                let a = $0.reading?.upNextPosition ?? Int.max, b = $1.reading?.upNextPosition ?? Int.max
                if a != b { return a < b }
                let comparison = $0.input.title.localizedStandardCompare($1.input.title)
                return comparison == .orderedSame ? $0.id.uuidString < $1.id.uuidString : comparison == .orderedAscending
            }.map(\.id))
    }

    func stats(for snapshot: ReadingLibrarySnapshot, filter: ReadingStatsFilter) -> UserReadingStats {
        if statsRevision != snapshot.revision {
            statsCache.removeAll(keepingCapacity: true)
            statsRevision = snapshot.revision
        }
        if let cached = statsCache[filter] { return cached }
        let signpost = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "Calculate reading stats", signpostID: signpost)
        defer { os_signpost(.end, log: log, name: "Calculate reading stats", signpostID: signpost) }
        let result = UserReadingStats(entries: snapshot.entries, filter: filter)
        if statsCache.count >= 32 { statsCache.removeAll(keepingCapacity: true) }
        statsCache[filter] = result
        return result
    }
}

@MainActor @Observable
final class ReadingLibraryCache {
    private(set) var snapshot = ReadingLibrarySnapshot()
    private(set) var isReady = false
    private(set) var profile = ReaderPersonality.summarize([], favorites: [])
    @ObservationIgnored let worker = ReadingLibraryWorker()

    func update(_ inputs: [ReadingBookInput]) async {
        do {
            // Coalesce import/sync/metadata bursts; keep the previous usable snapshot.
            if isReady { try await Task.sleep(for: .milliseconds(250)) }
            let result = try await worker.prepare(inputs)
            try Task.checkCancellation()
            snapshot = result
            if profile != result.profile { profile = result.profile }
            isReady = true
        } catch { /* Superseded work must never replace the latest library. */ }
    }
}

private struct ReadingLibraryKey: EnvironmentKey {
    static let defaultValue: ReadingLibraryCache? = nil
}
extension EnvironmentValues {
    var readingLibrary: ReadingLibraryCache? {
        get { self[ReadingLibraryKey.self] }
        set { self[ReadingLibraryKey.self] = newValue }
    }
}

/// Isolate full-library observation from tab selection and scrolling state.
struct ReadingLibraryObserver: View {
    let cache: ReadingLibraryCache
    @Query(filter: #Predicate<Book> { !$0.isRemovedFromLibrary }, sort: \Book.title) private var books: [Book]

    var body: some View {
        let inputs = books.map(ReadingBookInput.init)
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            .task(id: inputs) { await cache.update(inputs) }
    }
}

/// Display-only guesses never become catalog facts or stop enrichment retries.
/// Each field keeps its own provenance; verified values and reader moods win.
struct CatalogStatsGuess: Sendable {
    let kind: BookFictionKind
    let genres: Set<String>
    let moods: [String]
    let kindReason: String?
    let genreReason: String?
    let moodReason: String

    init(title: String, categories: [String], context: [String], knownKind: BookFictionKind?,
         knownGenres: Set<String>, directMoods: CatalogMoodEstimate) {
        let catalog = Self.key((categories + context).joined(separator: " "))
        let titleText = Self.key(title)
        func contains(_ text: String, _ phrase: String) -> Bool {
            text.contains(" " + phrase + " ")
        }
        // Specific forms beat loose topics: a historical novel is still fiction.
        let forms: [(BookFictionKind, [String])] = [
            (.nonfiction, ["nonfiction", "non fiction", "memoir", "memoirs", "autobiography", "biography", "true story", "true crime"]),
            (.fiction, ["a novel", "the novel", "this novel", "debut novel", "novella", "short stories", "fiction", "fantasy", "romance", "thriller"])
        ]
        func form(_ text: String) -> (BookFictionKind, String)? {
            for (kind, terms) in forms {
                if let term = terms.first(where: { contains(text, $0) }) { return (kind, term) }
            }
            return nil
        }
        let catalogForm = form(catalog)
        let titleForm = form(titleText)
        let inferredGenres = knownGenres.isEmpty ? GenreTaxonomy.normalized(categories + context, isOpenLibrary: true) : []
        let titleGenres = knownGenres.isEmpty && inferredGenres.isEmpty ? GenreTaxonomy.normalized([title], isOpenLibrary: true) : []
        let probableGenres = knownGenres.isEmpty ? inferredGenres : knownGenres
        let nonfictionGenres: Set<String> = ["Memoir", "Biography", "History", "Science", "Technology", "Psychology", "Philosophy", "Self help", "Business", "Health", "Education", "True crime", "Cooking", "Politics", "Religion", "Travel", "Art"]
        if let knownKind {
            kind = knownKind; kindReason = nil
        } else if let (value, term) = catalogForm {
            kind = value; kindReason = "Estimated from catalog context: “\(term)”"
        } else if !probableGenres.isEmpty {
            kind = probableGenres.isDisjoint(with: nonfictionGenres) ? .fiction : .nonfiction
            kindReason = "Estimated from catalog subjects"
        } else if let (value, term) = titleForm {
            kind = value; kindReason = "Low-confidence guess from title: “\(term)”"
        } else if !titleGenres.isEmpty {
            kind = titleGenres.isDisjoint(with: nonfictionGenres) ? .fiction : .nonfiction
            kindReason = "Low-confidence guess from title"
        } else {
            kind = .fiction; kindReason = "Low-confidence default: no useful catalog context"
        }
        if !knownGenres.isEmpty {
            genres = knownGenres; genreReason = nil
        } else if !inferredGenres.isEmpty {
            genres = inferredGenres; genreReason = "Estimated from catalog context"
        } else if !titleGenres.isEmpty {
            genres = titleGenres; genreReason = "Low-confidence guess from title"
        } else {
            genres = [kind == .fiction ? "General fiction" : "General nonfiction"]
            genreReason = kindReason?.hasPrefix("Low-confidence") == true
                ? "Low-confidence default: limited catalog context" : "Estimated from fiction/nonfiction classification"
        }
        if !directMoods.moods.isEmpty {
            moods = directMoods.moods; moodReason = "Estimated from catalog tags"
            return
        }
        let tones: [(String, [String])] = [
            ("funny", ["hilarious", "humorous", "laugh out loud", "witty", "comedy"]),
            ("dark", ["dark fantasy", "horror", "sinister", "terrifying", "macabre"]),
            ("tense", ["suspense", "suspenseful", "thriller", "nail biting"]),
            ("mysterious", ["mystery", "murder investigation", "detective"]),
            ("adventurous", ["adventure", "adventurous", "quest", "epic journey"]),
            ("sad", ["heartbreaking", "tragic", "tragedy", "grief"]),
            ("hopeful", ["hopeful", "optimistic", "hope filled"]),
            ("lighthearted", ["lighthearted", "light hearted", "feel good", "playful"]),
            ("emotional", ["emotional", "poignant", "heartfelt"]),
            ("inspiring", ["inspiring", "inspirational", "motivational", "empowering"]),
            ("reflective", ["reflective", "contemplative", "introspective", "thought provoking"]),
            ("informative", ["informative", "practical guide", "explains", "research", "handbook"])
        ]
        func tone(_ text: String) -> [String] {
            tones.filter { $0.1.contains(where: { contains(text, $0) }) }.map(\.0)
        }
        let catalogTone = tone(catalog)
        if !catalogTone.isEmpty {
            moods = Array(catalogTone.prefix(3)).sorted(); moodReason = "Estimated from catalog description and subjects"
            return
        }
        let genreMoods: [(Set<String>, String)] = [
            (["Horror", "Dystopian"], "dark"), (["Thriller", "Crime", "True crime"], "tense"),
            (["Mystery"], "mysterious"), (["Fantasy", "Science fiction", "Adventure", "Western"], "adventurous"),
            (["Romance", "Drama"], "emotional"), (["Humor"], "funny"), (["Self help"], "inspiring"),
            (["Memoir", "Biography", "Poetry", "Literary", "Philosophy", "Essays", "Classics"], "reflective")
        ]
        let resolvedGenres = genres
        let related = genreMoods.filter { !$0.0.isDisjoint(with: resolvedGenres) }.map(\.1)
        if !related.isEmpty {
            moods = Array(Set(related)).sorted()
            moodReason = genreReason?.hasPrefix("Low-confidence") == true
                ? "Low-confidence mood guess from title-derived genre" : "Estimated from genre; tone may differ"
        } else {
            let titleTone = tone(titleText)
            if !titleTone.isEmpty {
                moods = Array(titleTone.prefix(2)).sorted(); moodReason = "Low-confidence mood guess from title"
            } else {
                moods = [kind == .nonfiction ? "informative" : "reflective"]
                moodReason = "Low-confidence mood default: limited tone context"
            }
        }
    }

    private static func key(_ text: String) -> String {
        let stripped = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return " " + stripped.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ") + " "
    }
}
