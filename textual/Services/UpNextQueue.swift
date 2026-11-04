import Foundation
import CryptoKit
import SwiftData

/// Queue membership belongs to a library entry, never the shared catalog.
@MainActor
enum UpNextQueue {
    static func books(in archive: [Book]) -> [Book] {
        archive.filter { !$0.isRemovedFromLibrary }.map { ($0, $0.importedReading) }.filter { book, reading in
            guard reading?.status != "currently-reading", reading?.upNextExcluded != true else { return false }
            return reading?.upNextPosition != nil || (reading?.tags.contains { tag in
                tag.lowercased().filter(\.isLetter) == "upnext"
            } ?? false)
        }.sorted { lhs, rhs in
            let a = lhs.1?.upNextPosition ?? Int.max
            let b = rhs.1?.upNextPosition ?? Int.max
            if a != b { return a < b }
            let comparison = lhs.0.title.localizedStandardCompare(rhs.0.title)
            return comparison == .orderedSame ? lhs.0.id.uuidString < rhs.0.id.uuidString : comparison == .orderedAscending
        }.map { $0.0 }
    }

    /// Append once, keeping both the current order and the book's reading status.
    static func add(_ book: Book, context: ModelContext, repository: LibraryRepository?) throws {
        guard book.modelContext === context, !book.isRemovedFromLibrary,
              metadata(for: book).status != "currently-reading" else { throw ReadingActionError.unavailable }
        let archive = try context.fetch(FetchDescriptor<Book>(predicate: #Predicate { !$0.isRemovedFromLibrary }))
        let queue = books(in: archive)
        guard !queue.contains(where: { $0.id == book.id }) else { return }
        try save(queue + [book], context: context, repository: repository)
    }

    static func moving(_ id: UUID, to target: UUID, in books: [Book]) -> [Book] {
        guard let source = books.firstIndex(where: { $0.id == id }),
              let destination = books.firstIndex(where: { $0.id == target }), source != destination else { return books }
        var result = books
        result.insert(result.remove(at: source), at: destination)
        return result
    }

    static func save(_ ordered: [Book], removing removed: Book? = nil,
                     context: ModelContext, repository: LibraryRepository?) throws {
        var changed: [Book] = []
        let originals = (ordered + (removed.map { [$0] } ?? [])).map { ($0, $0.storyGraphData) }
        do {
            for (index, book) in ordered.enumerated() {
                var reading = metadata(for: book)
                guard reading.upNextPosition != index || reading.upNextExcluded != false else { continue }
                reading.upNextPosition = index
                reading.upNextExcluded = false
                book.storyGraphData = try JSONEncoder().encode(reading)
                changed.append(book)
            }
            if let removed {
                var reading = metadata(for: removed)
                reading.upNextPosition = nil
                reading.upNextExcluded = true
                removed.storyGraphData = try JSONEncoder().encode(reading)
                changed.append(removed)
            }
            if let repository { try repository.save(changed) }
            else { try context.save() }
        } catch {
            context.rollback()
            for (book, original) in originals { book.storyGraphData = original }
            throw error
        }
    }

    static func metadata(for book: Book) -> StoryGraphReadingData {
        book.importedReading ?? StoryGraphReadingData(
            sourceKey: SHA256.hash(data: Data(book.id.uuidString.utf8)).map { String(format: "%02x", $0) }.joined(),
            status: "to-read", dateAdded: nil, lastDateRead: nil, periods: [], readCount: nil,
            rating: nil, format: "", moods: [], pace: "", tags: [], owned: nil, originalFields: [:])
    }
}
