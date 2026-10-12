import Foundation
import SwiftData

/// Structured choices remain separate from prose. No reading dates or import
/// provenance are included in the payload that can contribute to discovery.
struct ReaderReviewContent: Codable, Equatable, Sendable {
    enum Pace: String, Codable, CaseIterable, Sendable { case fast, medium, slow }
    enum Fiction: String, Codable, Sendable { case fiction, nonfiction }
    enum Visibility: String, Codable, Sendable { case `private`, `public` }
    var version = 1
    /// Quarter-star units: 0...20 represents 0...5 stars, with nil = unrated.
    var rating: Int?
    var body = ""
    var spoilers = false
    var moods: [String] = []
    var pace: Pace?
    var genres: [String] = []
    var fiction: Fiction?
    var visibility: Visibility = .private
    var contribute = false

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
        result.genres = try terms(genres)
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
    let fiction: Distribution?
    let rating: Distribution?
    let moods: Distribution?
    let genres: Distribution?
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

    var content: ReaderReviewContent? { try? JSONDecoder().decode(ReaderReviewContent.self, from: contentData) }
    var remote: RemoteReaderReview? { remoteData.flatMap { try? JSONDecoder().decode(RemoteReaderReview.self, from: $0) } }
    var pending: ReaderReviewMutation? { pendingData.flatMap { try? JSONDecoder().decode(ReaderReviewMutation.self, from: $0) } }
    var conflict: RemoteReaderReview? { conflictData.flatMap { try? JSONDecoder().decode(RemoteReaderReview.self, from: $0) } }

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
