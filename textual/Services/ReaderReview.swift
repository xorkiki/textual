import Foundation
import SwiftData

/// Structured choices remain separate from prose. No reading dates or import
/// provenance are included in the payload that can contribute to discovery.
struct ReaderReviewContent: Codable, Equatable, Sendable {
    enum Pace: String, Codable, CaseIterable, Sendable { case fast, medium, slow }
    enum Visibility: String, Codable, Sendable { case `private`, `public` }
    var version = 1
    /// Quarter-star units: 0...20 represents 0...5 stars, with nil = unrated.
    var rating: Int?
    var body = ""
    var spoilers = false
    var moods: [String] = []
    var pace: Pace?
    var visibility: Visibility = .private
    var contribute = false

    var hasAssessment: Bool {
        rating != nil || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !moods.isEmpty || pace != nil
    }

    func validated() throws -> Self {
        guard version == 1, rating.map({ (0...20).contains($0) }) ?? true,
              body.unicodeScalars.count <= 20_000 else { throw ReaderReviewError.invalidContent }
        var result = self
        func terms(_ values: [String]) throws -> [String] {
            let values = Array(Set(values)).sorted()
            guard values.count <= 12, values.allSatisfy({
                $0.range(of: "^[a-z][a-z0-9-]{0,63}$", options: .regularExpression) != nil
            }) else { throw ReaderReviewError.invalidContent }
            return values
        }
        result.moods = try terms(moods)
        return result
    }
}

struct ReaderReviewTerm: Codable, Sendable {
    let kind: String
    let slug: String
    let label: String
}

struct RemoteReaderReview: Codable, Equatable, Sendable {
    let workID: UUID
    let bookID: UUID
    let revision: Int64
    let content: ReaderReviewContent
    let deleted: Bool
}

struct ReaderReviewMutation: Codable, Sendable {
    let expectedUserID: UUID
    let operationID: UUID
    let bookID: UUID
    let expectedRevision: Int64
    let content: ReaderReviewContent
    let deleted: Bool
    enum CodingKeys: String, CodingKey {
        case expectedUserID = "p_expected_user_id", operationID = "p_operation_id"
        case bookID = "p_book_id", expectedRevision = "p_expected_revision"
        case content = "p_content", deleted = "p_deleted"
    }
}
struct ReaderReviewResult: Codable, Sendable {
    enum Status: String, Codable, Sendable { case applied, conflict }
    let status: Status
    let review: RemoteReaderReview?
}

struct CommunityReviewSummary: Codable, Equatable, Sendable {
    struct Distribution: Codable, Equatable, Sendable {
        let contributors: Int
        let counts: [String: Int]
        func fraction(for term: String) -> Double? {
            guard contributors > 0 else { return nil }
            return Double(counts[term, default: 0]) / Double(contributors)
        }
    }
    let minimumContributors: Int
    let pace: Distribution?
    let rating: Distribution?
    let moods: Distribution?
}

/// Stored inside the existing account-specific SwiftData container. Draft edits
/// are independent of the frozen submission, so retries cannot publish new edits.
@Model
final class ReaderReviewDraft {
    @Attribute(.unique) var key: String
    var userID: UUID
    var localBookID: UUID
    var contentData: Data
    var remoteData: Data?
    var pendingData: Data?
    var conflictData: Data?
    var hasLoadedRemote = false
    /// Distinguishes a deliberately cleared draft from an empty downloaded cache.
    var hasLocalEdits: Bool = false

    var content: ReaderReviewContent? { try? JSONDecoder().decode(ReaderReviewContent.self, from: contentData) }
    var remote: RemoteReaderReview? { remoteData.flatMap { try? JSONDecoder().decode(RemoteReaderReview.self, from: $0) } }
    var pending: ReaderReviewMutation? { pendingData.flatMap { try? JSONDecoder().decode(ReaderReviewMutation.self, from: $0) } }
    var conflict: RemoteReaderReview? { conflictData.flatMap { try? JSONDecoder().decode(RemoteReaderReview.self, from: $0) } }

    /// Only explicitly saved values appear as the review; unsaved edits stay drafts.
    var savedContent: ReaderReviewContent? {
        if let pending { return pending.deleted ? nil : pending.content }
        return remote.flatMap { $0.deleted ? nil : $0.content }
    }
    var hasUnsavedChanges: Bool {
        content != (savedContent ?? ReaderReviewContent())
    }
    var statusLabel: String {
        if conflict != nil { return "Needs your attention" }
        if pending != nil { return "Waiting to sync" }
        if hasUnsavedChanges { return "Draft saved on this device" }
        return savedContent == nil ? "No review yet" : "Saved · Only you"
    }

    init(userID: UUID, localBookID: UUID, content: ReaderReviewContent) throws {
        key = Self.key(userID: userID, bookID: localBookID)
        self.userID = userID; self.localBookID = localBookID
        contentData = try JSONEncoder().encode(content.validated())
    }
    static func key(userID: UUID, bookID: UUID) -> String { "\(userID.uuidString):\(bookID.uuidString)" }
}

enum ReaderReviewError: Error {
    case invalidContent, bookNotSynced, loadRemoteFirst, submissionPending, conflict, invalidResponse
}


/// A single precedence rule for book detail, the reviews list, and editor prefilling.
/// Imports remain account-private library data; displaying them creates no submissions.
@MainActor
struct ReaderReviewPresentation {
    let draft: ReaderReviewDraft?
    let imported: ReaderReviewContent?
    private let originalImportedBody: String?

    init(book: Book, draft: ReaderReviewDraft?) {
        self.draft = draft
        let reading = book.importedReading
        imported = Self.importedContent(reading)
        originalImportedBody = reading?.originalFields["Review"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Also repairs untouched copies saved by earlier versions, without changing
    /// stored import data, frozen submissions, or prose the reader has since edited.
    private func readable(_ value: ReaderReviewContent?) -> ReaderReviewContent? {
        guard var value else { return nil }
        if let originalImportedBody, value.body == originalImportedBody, let imported {
            value.body = imported.body
            value.spoilers = value.spoilers || imported.spoilers
        }
        return value
    }
    static func importedContent(_ reading: StoryGraphReadingData?) -> ReaderReviewContent? {
        guard let reading else { return nil }
        var content = ReaderReviewContent()
        if let rating = reading.rating, rating.isFinite, (0...5).contains(rating) {
            content.rating = Int((rating * 4).rounded())
        }
        let text = CatalogDescriptionHTML.plainReview(reading.originalFields["Review"] ?? "")
        content.body = text.body
        content.spoilers = text.spoilers
        return content.hasAssessment ? content : nil
    }
    var content: ReaderReviewContent? {
        // A withdrawal is authoritative too: don't resurrect an older imported review.
        if draft?.pending != nil || draft?.remote != nil { return readable(draft?.savedContent) }
        return imported
    }
    var isImported: Bool { draft?.pending == nil && draft?.remote == nil && imported != nil }
    var hasDraftChanges: Bool {
        guard let draft, draft.hasLocalEdits || draft.hasUnsavedChanges else { return false }
        return readable(draft.content) != (content ?? .init())
    }
    var editorContent: ReaderReviewContent {
        if let draft, draft.hasLocalEdits || draft.hasUnsavedChanges { return readable(draft.content) ?? .init() }
        return content ?? .init()
    }
    var isVisible: Bool { content != nil || hasDraftChanges || draft?.pending != nil || draft?.conflict != nil }
    var statusLabel: String {
        if draft?.conflict != nil { return "Needs your attention" }
        if draft?.pending != nil { return "Waiting to sync" }
        if hasDraftChanges { return "Draft saved on this device" }
        return isImported ? "Imported · Only you" : draft?.statusLabel ?? "No review yet"
    }
    static func rows(books: [Book], drafts: [ReaderReviewDraft], userID: UUID?, search: String)
        -> [(book: Book, review: ReaderReviewPresentation)] {
        let byBook = Dictionary(drafts.filter { $0.userID == userID }.map { ($0.localBookID, $0) },
                                uniquingKeysWith: { first, _ in first })
        return books.compactMap { book in
            let review = Self(book: book, draft: byBook[book.id])
            guard review.isVisible,
                  search.isEmpty || book.title.localizedCaseInsensitiveContains(search)
                    || book.author.localizedCaseInsensitiveContains(search) else { return nil }
            return (book, review)
        }
    }
}
