import XCTest
import SwiftData
import SwiftUI
@testable import textual

@MainActor
final class BookReadingActionTests: XCTestCase {
    private func fixture() throws -> (ModelContainer, Book) {
        let container = try ModelContainer(for: Book.self, Tag.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let book = Book(title: "Test book", author: "Author", isbn: "")
        container.mainContext.insert(book)
        try BookReadingActions.setStatus("currently-reading", book: book, context: container.mainContext, repository: nil)
        return (container, book)
    }

    func testJournalPersistsAndSurvivesReimport() throws {
        let (container, book) = try fixture()
        try BookReadingActions.append(" A quotation. ", action: .quote, book: book, context: container.mainContext, repository: nil)
        try BookReadingActions.append("A private thought.", action: .note, book: book, context: container.mainContext, repository: nil)
        try BookReadingActions.updateProgress(42, unit: .page, book: book, context: container.mainContext, repository: nil)
        let decoded = try JSONDecoder().decode(StoryGraphReadingData.self, from: XCTUnwrap(book.storyGraphData))
        XCTAssertEqual(decoded.journal?.quotes.first?.text, "A quotation.")
        XCTAssertEqual(decoded.journal?.notes.first?.text, "A private thought.")
        XCTAssertEqual(decoded.journal?.progress?.label, "Page 42")
        var imported = decoded
        imported.journal = nil
        XCTAssertEqual(imported.preservingQueue(from: decoded).journal, decoded.journal)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Book>()).first?.importedReading?.journal, decoded.journal)
    }

    func testInvalidEntriesDoNotChangeBook() throws {
        let (container, book) = try fixture()
        let before = book.storyGraphData
        for value in [-1, 101] {
            XCTAssertThrowsError(try BookReadingActions.updateProgress(value, unit: .percent, book: book, context: container.mainContext, repository: nil))
        }
        XCTAssertThrowsError(try BookReadingActions.append("   ", action: .note, book: book, context: container.mainContext, repository: nil))
        XCTAssertEqual(book.storyGraphData, before)
    }

    func testFinishingIsIdempotentPreservesJournalAndClearsQueue() throws {
        let (container, book) = try fixture()
        try BookReadingActions.append("Keep this", action: .note, book: book, context: container.mainContext, repository: nil)
        var data = try XCTUnwrap(book.importedReading)
        data.periods = [.init(startedOn: "2026-10-01", finishedOn: nil)]
        data.upNextPosition = 2
        book.storyGraphData = try JSONEncoder().encode(data)
        for _ in 0..<2 {
            try BookReadingActions.setStatus("read", book: book, context: container.mainContext, repository: nil)
        }
        let finished = try XCTUnwrap(book.importedReading)
        XCTAssertEqual(finished.status, "read")
        XCTAssertEqual(finished.readCount, 1)
        XCTAssertEqual(finished.periods.count, 1)
        XCTAssertNotNil(finished.periods[0].finishedOn)
        XCTAssertEqual(finished.periods[0].startedOn, "2026-10-01")
        XCTAssertEqual(finished.journal?.progress?.value, 100)
        XCTAssertEqual(finished.journal?.notes.first?.text, "Keep this")
        XCTAssertNil(finished.upNextPosition)
        XCTAssertTrue(UpNextQueue.books(in: [book]).isEmpty)
    }

    func testOldReadingPayloadStillDecodes() throws {
        let (container, book) = try fixture()
        defer { withExtendedLifetime(container) {} }
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(book.storyGraphData)) as? [String: Any])
        json.removeValue(forKey: "journal")
        let decoded = try JSONDecoder().decode(StoryGraphReadingData.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.journal)
        XCTAssertEqual(decoded.status, "currently-reading")
    }

    func testArcFitsEdgesAndCancelsOutsideTargets() {
        for size in [CGSize(width: 320, height: 568), CGSize(width: 393, height: 852), CGSize(width: 852, height: 393)] {
            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 0, dy: 24)
            for x in [CGFloat(20), size.width / 2, size.width - 20] {
                for y in [CGFloat(50), size.height / 2, size.height - 50] {
                    let origin = CGPoint(x: x, y: y)
                    let layout = HoldSlideLayout(origin: origin, bounds: bounds, count: 4)
                    XCTAssertNil(layout.target(at: origin))
                    XCTAssertNil(layout.target(at: CGPoint(x: -100, y: -100)))
                    for (index, center) in layout.centers.enumerated() {
                        XCTAssertTrue(bounds.insetBy(dx: 26, dy: 26).contains(center), "Arc clipped at \(origin): \(center)")
                        XCTAssertEqual(layout.target(at: center), index)
                        for other in layout.centers.dropFirst(index + 1) {
                            XCTAssertGreaterThan(hypot(center.x - other.x, center.y - other.y), HoldSlideLayout.hitRadius * 2)
                        }
                    }
                }
            }
        }
    }

    func testJournalUsesExistingDurableLibraryOutboxAndRollsBackOnFailure() throws {
        let (container, book) = try fixture()
        book.googleBooksVolumeId = "test-volume"
        let userID = UUID()
        let repository = LibraryRepository(userID: userID, modelContext: container.mainContext,
                                           transport: OfflineReadingTransport(userID: userID))
        try BookReadingActions.append("Queued quote", action: .quote, book: book,
                                      context: container.mainContext, repository: repository)
        let change = try JSONDecoder().decode(LibraryChange.self, from: XCTUnwrap(book.pendingOperationData))
        XCTAssertEqual(change.readingData?.journal?.quotes.first?.text, "Queued quote")
        XCTAssertEqual(change.entryID, book.id)
        let before = book.storyGraphData
        repository.stop()
        XCTAssertThrowsError(try BookReadingActions.setStatus("read", book: book,
            context: container.mainContext, repository: repository))
        XCTAssertEqual(book.storyGraphData, before)
        XCTAssertEqual(book.importedReading?.status, "currently-reading")
    }

    func testMenuAppearance() {
        for x in [CGFloat(24), CGFloat(196), CGFloat(369)] {
            let layout = HoldSlideLayout(origin: CGPoint(x: x, y: 290),
                bounds: CGRect(x: 0, y: 62, width: 393, height: 756), count: 4)
            let preview = ZStack {
                Color.inkwell
                VStack {
                    Text("CURRENTLY READING").font(.designSystem(.sectionHeading))
                    HStack(spacing: 20) {
                        ForEach(0..<3) { _ in Rectangle().fill(Color.moss).frame(width: 100, height: 155) }
                    }
                    Spacer()
                }.padding(.top, 110).foregroundStyle(Color.paper)
                HoldSlideOverlay(actions: BookQuickAction.allCases.map(\.menuAction), layout: layout, highlighted: 1)
            }.frame(width: 393, height: 852)
            let renderer = ImageRenderer(content: preview)
            renderer.scale = 2
            if let image = renderer.uiImage {
                let attachment = XCTAttachment(image: image)
                attachment.name = "Reading quick actions — x \(Int(x))"
                attachment.lifetime = .keepAlways
                add(attachment)
            } else { XCTFail("Menu could not render") }
        }
    }

    func testRadialActionsExcludeDNFAndUseExistingProgressIcon() {
        XCTAssertEqual(BookQuickAction.allCases.count, 4)
        XCTAssertEqual(BookQuickAction.progress.icon, .pieChart)
        XCTAssertEqual(BookQuickAction.finish.icon, .star)
    }
}

private actor OfflineReadingTransport: LibrarySyncTransport {
    let userID: UUID
    init(userID: UUID) { self.userID = userID }
    func authenticatedUserID() async throws -> UUID { userID }
    func synchronize(_ request: LibrarySyncRequest) async throws -> LibrarySyncResponse { throw URLError(.notConnectedToInternet) }
}
