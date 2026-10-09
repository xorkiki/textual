import Foundation
import CryptoKit

/// Date-only values stay date-only. Import never invents a timezone or a missing date.
struct ReadingPeriod: Codable, Equatable, Sendable {
    var startedOn: String?
    var finishedOn: String?
}

/// Owner-private reading metadata, stored with the account's library entry, never
/// with the shared catalog. Original columns retain details for future features.
struct StoryGraphReadingData: Codable, Equatable, Sendable {
    var version: Int = 1
    let sourceKey: String
    let status: String
    let dateAdded: String?
    let lastDateRead: String?
    let periods: [ReadingPeriod]
    let readCount: Int?
    let rating: Double?
    let format: String
    let moods: [String]
    let pace: String
    let tags: [String]
    let owned: Bool?
    let originalFields: [String: String]

    var statusLabel: String {
        switch status {
        case "read": return "Read"
        case "to-read": return "To read"
        case "currently-reading": return "Currently reading"
        case "did-not-finish": return "Did not finish"
        default: return originalFields["Read Status"] ?? status
        }
    }
}

struct StoryGraphRecord: Sendable {
    let row: Int
    let title: String
    let author: String
    let isbn: String?
    let reading: StoryGraphReadingData
    var catalogID: String { "storygraph:\(reading.sourceKey)" }
}

struct StoryGraphDocument: Sendable {
    let records: [StoryGraphRecord]
    let duplicateRows: Int
    let warnings: [String]
    var statusCounts: [String: Int] {
        Dictionary(grouping: records, by: { $0.reading.status }).mapValues(\.count)
    }
}

enum StoryGraphImportError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

enum StoryGraphImporter {
    static let maximumFileBytes = 10 * 1024 * 1024
    static let maximumRecords = 10_000
    static let maximumMetadataBytes = 65_536

    /// Called off the main actor by the import screen. Security-scoped access
    /// lasts only for the read; no persistent bookmark or source copy is retained.
    static func read(url: URL) throws -> StoryGraphDocument {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile != false, (values.fileSize ?? 0) <= maximumFileBytes else {
            throw StoryGraphImportError.invalid("Choose a CSV file smaller than 10 MB.")
        }
        return try parse(Data(contentsOf: url))
    }

    static func parse(_ data: Data) throws -> StoryGraphDocument {
        guard data.count <= maximumFileBytes, var text = String(data: data, encoding: .utf8) else {
            throw StoryGraphImportError.invalid("Choose a UTF-8 StoryGraph CSV export smaller than 10 MB.")
        }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        let rows = try csvRows(text)
        guard let first = rows.first else { throw StoryGraphImportError.invalid("This file is empty.") }
        let headers = first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard Set(headers).count == headers.count, !headers.contains("") else {
            throw StoryGraphImportError.invalid("The CSV contains blank or repeated column headings.")
        }
        let required = ["Title", "Authors", "ISBN/UID", "Read Status", "Date Added", "Dates Read", "Read Count"]
        let missing = required.filter { !headers.contains($0) }
        guard missing.isEmpty else {
            throw StoryGraphImportError.invalid("This doesn't look like a StoryGraph export. Missing columns: \(missing.joined(separator: ", ")).")
        }
        var records: [StoryGraphRecord] = []
        var seen: [String: StoryGraphReadingData] = [:]
        var duplicates = 0
        var warnings: [String] = []
        for (offset, row) in rows.dropFirst().enumerated() {
            try Task.checkCancellation()
            let number = offset + 2
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { continue }
            guard row.count == headers.count else {
                throw StoryGraphImportError.invalid("Row \(number) has \(row.count) columns; expected \(headers.count). Nothing has been imported.")
            }
            let fields = Dictionary(uniqueKeysWithValues: zip(headers, row))
            func value(_ key: String) -> String { (fields[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            let title = value("Title")
            let author = value("Authors")
            guard !title.isEmpty, title.count <= 1000, author.count <= 1000 else {
                throw StoryGraphImportError.invalid("Row \(number) needs a title of at most 1,000 characters and authors of at most 1,000 characters.")
            }
            let identifier = value("ISBN/UID")
            let isbn = normalizedISBN(identifier)
            // UID identifies editions when supplied. A deterministic fallback also
            // makes exports without an ISBN safe to import repeatedly.
            let identity = isbn.map { "isbn:\($0)" }
                ?? (identifier.isEmpty ? "name:\(normalizedName(title))|\(normalizedName(author))" : "uid:\(identifier)")
            let sourceKey = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            let status = value("Read Status").lowercased()
            if !["read", "to-read", "currently-reading", "did-not-finish"].contains(status) {
                warnings.append("Row \(number): an unfamiliar reading status was preserved as supplied.")
            }
            func date(_ raw: String, _ label: String) -> String? {
                guard !raw.isEmpty else { return nil }
                guard let parsed = normalizedDate(raw) else {
                    warnings.append("Row \(number): \(label) was preserved in its original form but isn't a complete date.")
                    return nil
                }
                return parsed
            }
            let added = date(value("Date Added"), "date added")
            let lastRead = date(value("Last Date Read"), "last read date")
            var periods: [ReadingPeriod] = []
            for interval in value("Dates Read").split(separator: ",") {
                let raw = interval.trimmingCharacters(in: .whitespacesAndNewlines)
                // StoryGraph uses YYYY/MM/DD-YYYY/MM/DD; either endpoint may be blank.
                let pieces = raw.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
                if pieces.count == 2 {
                    let start = date(pieces[0], "reading start")
                    let finish = date(pieces[1], "reading finish")
                    if start != nil || finish != nil { periods.append(.init(startedOn: start, finishedOn: finish)) }
                } else if let finish = normalizedDate(raw) {
                    periods.append(.init(startedOn: nil, finishedOn: finish))
                } else {
                    warnings.append("Row \(number): a reading interval was preserved in its original form.")
                }
            }
            if periods.isEmpty, let lastRead { periods.append(.init(startedOn: nil, finishedOn: lastRead)) }
            let countText = value("Read Count")
            let count = countText.isEmpty ? nil : Int(countText)
            guard countText.isEmpty || (count != nil && count! >= 0 && count! <= 1_000_000) else {
                throw StoryGraphImportError.invalid("Row \(number) has an invalid read count.")
            }
            let ratingText = value("Star Rating")
            let rating = ratingText.isEmpty ? nil : Double(ratingText)
            guard ratingText.isEmpty || (rating != nil && rating!.isFinite && (0...5).contains(rating!)) else {
                throw StoryGraphImportError.invalid("Row \(number) has a rating outside 0–5.")
            }
            func list(_ key: String) -> [String] {
                value(key).split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            }
            let ownedText = value("Owned?").lowercased()
            let owned: Bool? = ownedText == "yes" ? true : (ownedText == "no" ? false : nil)
            let reading = StoryGraphReadingData(sourceKey: sourceKey, status: status, dateAdded: added,
                lastDateRead: lastRead, periods: periods, readCount: count, rating: rating,
                format: value("Format"), moods: list("Moods"), pace: value("Pace"), tags: list("Tags"),
                owned: owned, originalFields: fields)
            guard try JSONEncoder().encode(reading).count <= maximumMetadataBytes else {
                throw StoryGraphImportError.invalid("Row \(number) contains more than 64 KB of reading notes. Nothing has been imported.")
            }
            if let previous = seen[sourceKey] {
                guard previous == reading else {
                    throw StoryGraphImportError.invalid("Row \(number) repeats a book with different reading data. Review those rows before importing; nothing has been changed.")
                }
                duplicates += 1
                continue
            }
            seen[sourceKey] = reading
            records.append(.init(row: number, title: title, author: author, isbn: isbn, reading: reading))
            guard records.count <= maximumRecords else {
                throw StoryGraphImportError.invalid("Import at most 10,000 books in one file.")
            }
        }
        guard !records.isEmpty else { throw StoryGraphImportError.invalid("This export doesn't contain any books.") }
        return .init(records: records, duplicateRows: duplicates, warnings: warnings)
    }

    static func normalizedName(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Normalize valid ISBN-10 and ISBN-13 to one identity; reject StoryGraph UIDs
    /// and malformed identifiers instead of pretending they are ISBNs.
    static func normalizedISBN(_ raw: String) -> String? {
        let s = raw.filter { !$0.isWhitespace && $0 != "-" }.uppercased()
        let bytes = Array(s.utf8)
        if bytes.count == 13, bytes.allSatisfy({ (48...57).contains($0) }) {
            let digits = bytes.map { Int($0 - 48) }
            guard digits.enumerated().reduce(0, { $0 + $1.element * ($1.offset % 2 == 0 ? 1 : 3) }) % 10 == 0 else { return nil }
            return s
        }
        if bytes.count == 10, bytes.prefix(9).allSatisfy({ (48...57).contains($0) }),
           bytes[9] == 88 || (48...57).contains(bytes[9]) {
            let digits = bytes.map { $0 == 88 ? 10 : Int($0 - 48) }
            guard digits.enumerated().reduce(0, { $0 + $1.element * (10 - $1.offset) }) % 11 == 0 else { return nil }
            let first12 = "978" + s.prefix(9)
            let sum = first12.utf8.enumerated().reduce(0) { $0 + Int($1.element - 48) * ($1.offset % 2 == 0 ? 1 : 3) }
            return first12 + String((10 - sum % 10) % 10)
        }
        return nil
    }

    static func normalizedDate(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        let pieces = value.split(separator: "-")
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2]),
              (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.year, from: date) == year,
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else { return nil }
        return value
    }

    /// RFC 4180-style CSV, including quoted commas, escaped quotes, CRLF and
    /// multiline reviews. No split-on-newline approximation or HTML execution.
    private static func csvRows(_ text: String) throws -> [[String]] {
        let bytes = Array(text.utf8)
        var rows: [[String]] = [], row: [String] = [], field: [UInt8] = []
        var quoted = false, closedQuote = false, i = 0
        func fail() -> StoryGraphImportError { .invalid("The CSV has an invalid quoted field near record \(rows.count + 1). Nothing has been imported.") }
        func finishField() { row.append(String(decoding: field, as: UTF8.self)); field.removeAll(keepingCapacity: true); closedQuote = false }
        func finishRow() throws {
            finishField()
            guard row.count <= 256, rows.count <= maximumRecords + 1 else { throw StoryGraphImportError.invalid("This CSV has too many rows or columns.") }
            rows.append(row); row.removeAll(keepingCapacity: true)
        }
        while i < bytes.count {
            if i % 4096 == 0 { try Task.checkCancellation() }
            let byte = bytes[i]
            if quoted {
                if byte == 34 {
                    if i + 1 < bytes.count, bytes[i + 1] == 34 { field.append(34); i += 1 }
                    else { quoted = false; closedQuote = true }
                } else { field.append(byte) }
            } else {
                switch byte {
                case 34:
                    guard field.isEmpty, !closedQuote else { throw fail() }
                    quoted = true
                case 44: finishField()
                case 10, 13:
                    try finishRow()
                    if byte == 13, i + 1 < bytes.count, bytes[i + 1] == 10 { i += 1 }
                default:
                    if closedQuote { if byte != 32 && byte != 9 { throw fail() } }
                    else { field.append(byte) }
                }
            }
            i += 1
        }
        guard !quoted else { throw fail() }
        if !row.isEmpty || !field.isEmpty || closedQuote { try finishRow() }
        return rows
    }
}
