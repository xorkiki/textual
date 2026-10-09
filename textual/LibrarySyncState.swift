import Foundation
import SwiftData

/// Committed in the same account store transaction as downloaded entries.
@Model
final class LibrarySyncState {
    @Attribute(.unique) var userID: UUID
    var revision: Int64 = 0

    init(userID: UUID) {
        self.userID = userID
    }
}
