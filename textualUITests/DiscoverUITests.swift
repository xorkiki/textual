import XCTest

/// Drives the debug Discover harness (real catalog fixture, in-memory store, no account).
/// Covers sit on the shared UIKit hold-slide surface, so visibility is checked by frame.
final class DiscoverUITests: XCTestCase {
    private let screen = CGRect(x: 0, y: 118, width: 402, height: 700)

    @MainActor private func launch(_ extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["--discover-ui-test"] + extra
        app.launch()
        return app
    }

    @MainActor private func page(_ app: XCUIApplication, _ tab: String = "forYou") -> XCUIElement {
        app.scrollViews["discover.page.\(tab)"]
    }

    @MainActor private func visibleCovers(_ app: XCUIApplication, tab: String = "forYou", timeout: TimeInterval = 15) -> [XCUIElement] {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let covers = page(app, tab).buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'discover.book.'"))
                .allElementsBoundByIndex.filter { screen.contains($0.frame) }
            if !covers.isEmpty { return covers }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return []
    }

    @MainActor private func cover(_ app: XCUIApplication, _ id: String, tab: String = "forYou") -> XCUIElement {
        page(app, tab).buttons[id]
    }

    /// Taps a cover's center; the hold-slide surface is UIKit, so XCUITest's hittability check doesn't apply.
    @MainActor private func tapCenter(_ app: XCUIApplication, _ element: XCUIElement) {
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: element.frame.midX, dy: element.frame.midY)).tap()
    }

    @MainActor private func waitFor(_ predicate: String, _ element: XCUIElement, timeout: TimeInterval = 3) {
        wait(for: [expectation(for: NSPredicate(format: predicate), evaluatedWith: element)], timeout: timeout)
    }

    @MainActor func testFourTabsSwitchByTapAndSwipe() throws {
        let app = launch()
        let ids = ["forYou", "trending", "explore", "friends"]
        let tabs = ids.map { app.buttons["discover.tab.\($0)"] }
        XCTAssertTrue(tabs[0].waitForExistence(timeout: 10))
        XCTAssertTrue(tabs.allSatisfy(\.exists), "all four tabs")
        XCTAssertFalse(visibleCovers(app).isEmpty, "For You shows covers")
        XCTAssertTrue(tabs[0].isSelected)

        tabs[1].tap()
        waitFor("isSelected == true", tabs[1])
        XCTAssertEqual(app.scrollViews["discover.page.trending"].frame.minX, 0, accuracy: 1)

        tabs[3].tap()
        XCTAssertTrue(app.staticTexts["Nothing here yet"].waitForExistence(timeout: 3), "Friends empty state")

        app.staticTexts["Nothing here yet"].swipeRight()
        waitFor("isSelected == true", tabs[2])
        XCTAssertEqual(app.scrollViews["discover.page.explore"].frame.minX, 0, accuracy: 1)
    }

    @MainActor func testScrollPositionSurvivesTabSwitchAndDetails() throws {
        let app = launch()
        guard let first = visibleCovers(app).first else { return XCTFail("no covers") }
        let firstID = first.identifier
        let startY = first.frame.minY
        app.swipeUp(velocity: .slow)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let scrolledY = cover(app, firstID).frame.minY
        XCTAssertLessThan(scrolledY, startY - 100, "scrolled down")

        app.buttons["discover.tab.explore"].tap()
        waitFor("isSelected == true", app.buttons["discover.tab.explore"])
        app.buttons["discover.tab.forYou"].tap()
        waitFor("isSelected == true", app.buttons["discover.tab.forYou"])
        XCTAssertEqual(cover(app, firstID).frame.minY, scrolledY, accuracy: 2, "position kept after switching tabs")

        guard let visible = visibleCovers(app).first else { return XCTFail("no visible cover") }
        let visibleID = visible.identifier
        let before = visible.frame
        tapCenter(app, visible)
        let back = app.buttons["navigation.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "existing book details open on tap")
        back.tap()
        XCTAssertTrue(cover(app, visibleID).waitForExistence(timeout: 3))
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        XCTAssertEqual(cover(app, visibleID).frame.minY, before.minY, accuracy: 2, "returns to the same place")
    }

    @MainActor func testScrollingNeitherOpensDetailsNorTriggersActions() throws {
        let app = launch()
        let covers = visibleCovers(app)
        XCTAssertFalse(covers.isEmpty)
        let ids = covers.map(\.identifier)
        for _ in 0..<2 { app.swipeUp(velocity: .slow) }
        for _ in 0..<2 { app.swipeDown(velocity: .slow) }
        XCTAssertFalse(app.buttons["navigation.back"].exists, "a scroll is not a tap")
        for id in ids { XCTAssertEqual(cover(app, id).value as? String ?? "", "", "a scroll never saves a book") }
    }

    /// Mirrors HoldSlideLayout so the test can slide to a known action.
    private func actionCenters(origin: CGPoint, bounds: CGRect, count: Int) -> [CGPoint] {
        let safe = bounds.insetBy(dx: 36, dy: 36)
        var best: [CGPoint] = []
        var bestScore = CGFloat.infinity
        for (radius, spread) in [(CGFloat(100), CGFloat.pi * 0.74), (CGFloat(132), CGFloat.pi * 0.55), (CGFloat(156), CGFloat.pi * 0.433)] {
            for step in 0..<72 {
                let direction = -CGFloat.pi / 2 + CGFloat(step) * .pi / 36
                let points = (0..<count).map { index -> CGPoint in
                    let angle = direction + (count > 1 ? CGFloat(index) / CGFloat(count - 1) - 0.5 : 0) * spread
                    return CGPoint(x: origin.x + cos(angle) * radius, y: origin.y + sin(angle) * radius)
                }
                let overflow = points.reduce(CGFloat.zero) { result, point in
                    result + pow(max(safe.minX - point.x, 0, point.x - safe.maxX), 2)
                        + pow(max(safe.minY - point.y, 0, point.y - safe.maxY), 2)
                }
                let score = overflow * 1000 + CGFloat(min(step, 72 - step)) + (radius - 100) * 2
                if score < bestScore { best = points; bestScore = score }
            }
        }
        return best
    }

    @MainActor func testHoldSlideReleaseSavesToArchiveAndSwitchesActions() throws {
        let app = launch()
        guard let target = visibleCovers(app).first(where: { $0.frame.midY > 300 && $0.frame.midY < 650 })
                ?? visibleCovers(app).first else { return XCTFail("no covers") }
        let id = target.identifier
        XCTAssertEqual(target.value as? String ?? "", "")
        let window = app.windows.firstMatch.frame
        let safeTop = app.buttons["discover.tab.forYou"].frame.minY - 8
        let bounds = CGRect(x: 0, y: safeTop, width: window.width, height: window.height - safeTop - 34)
        let origin = CGPoint(x: target.frame.midX, y: target.frame.midY)
        let read = actionCenters(origin: origin, bounds: bounds, count: 4)[0]
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: origin.x, dy: origin.y))
        let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: read.x, dy: read.y))
        start.press(forDuration: 0.5, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        waitFor("value == 'In your archive'", cover(app, id), timeout: 5)
        XCTAssertFalse(app.buttons["navigation.back"].exists, "a hold is not a tap")

        // Saved state is shared: opening it now shows the archived book's reading controls.
        tapCenter(app, cover(app, id))
        XCTAssertTrue(app.buttons["navigation.back"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Read"].waitForExistence(timeout: 3) || app.staticTexts["Read"].exists,
                      "status chosen in the hold menu")
    }

    /// Review gallery: one screenshot per tab plus catalog-book details.
    @MainActor func testScreenshotGallery() throws {
        let app = launch()
        func shot(_ name: String) {
            RunLoop.current.run(until: Date().addingTimeInterval(2.5))
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertFalse(visibleCovers(app).isEmpty)
        shot("1-for-you")
        for (index, tab) in ["trending", "explore", "friends"].enumerated() {
            app.buttons["discover.tab.\(tab)"].tap()
            shot("\(index + 2)-\(tab)")
        }
        app.buttons["discover.tab.trending"].tap()
        guard let book = visibleCovers(app, tab: "trending").first else { return XCTFail("no trending covers") }
        tapCenter(app, book)
        XCTAssertTrue(app.buttons["navigation.back"].waitForExistence(timeout: 5))
        shot("5-catalog-details")
    }

    @MainActor func testOfflineWithoutCacheShowsRetry() throws {
        let app = launch(["--discover-offline"])
        XCTAssertTrue(app.buttons["discover.retry"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'discover.book.'")).count == 0,
                      "nothing is invented")
    }
}
