import XCTest
import SwiftUI
import SwiftData
@testable import textual

@MainActor
final class UpNextPresentationTests: XCTestCase {
    func testUpNextRendersEmptyAndPopulatedShelves() throws {
        for count in [0, 4, 16] {
            let container = try ModelContainer(for: Book.self, Tag.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let books = (0..<count).map { Book(title: "Book \($0 + 1)", author: "Reader", isbn: "") }
            for book in books { container.mainContext.insert(book) }
            try UpNextQueue.save(books, context: container.mainContext, repository: nil)
            let state = ReaderShelfDrag()
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
            let host = UIHostingController(rootView: NavigationStack {
                UpNextView(repository: nil)
            }.modelContainer(container).environment(\.readerShelfDrag, state).textualScreenDefaults())
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true; window.rootViewController = nil }
            host.view.layoutIfNeeded()
            let frames = books.compactMap { state.frame(for: $0.id, in: window) }
            XCTAssertEqual(frames.count, count, "Up Next must not inherit the profile's 15-book limit.")
            if count >= 4 {
                XCTAssertEqual(frames[0].maxY, frames[1].maxY, accuracy: 1)
                XCTAssertEqual(frames[0].maxY, frames[2].maxY, accuracy: 1)
                XCTAssertEqual(frames[3].maxY - frames[0].maxY, 210, accuracy: 1)
            }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                host.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Up Next — \(count) books"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
