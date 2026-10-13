import XCTest

final class HoldSlideUITests: XCTestCase {
    @MainActor private func launch() -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["--hold-slide-ui-test"]
        app.launch()
        XCTAssertTrue(app.otherElements["hold.book.1"].waitForExistence(timeout: 10))
        return app
    }
    @MainActor private func book(_ app: XCUIApplication) -> XCUIElement { app.otherElements["hold.book.1"] }
    @MainActor private func result(_ app: XCUIApplication, _ expected: String) {
        let value = app.staticTexts["hold.result"]
        let matches = NSPredicate(format: "label == %@", expected)
        expectation(for: matches, evaluatedWith: value)
        waitForExpectations(timeout: 3)
    }
    @MainActor func testTapAndContinuousHoldSlideToEveryAction() {
        let app = launch()
        book(app).tap()
        result(app, "tap:1")
        for (index, action) in ["quote", "progress", "finish", "note"].enumerated() {
            let start = book(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let angle = -Double.pi / 2 + (Double(index) / 3 - 0.5) * Double.pi * 0.74
            let end = start.withOffset(CGVector(dx: cos(angle) * 100, dy: sin(angle) * 100))
            start.press(forDuration: 0.45, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.15)
            result(app, "\(action):1")
        }
    }
    @MainActor func testReleaseAtOriginOrAwayCancelsWithoutOpeningDetails() {
        let app = launch()
        book(app).press(forDuration: 0.45)
        result(app, "none")
        let start = book(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.45, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 180)))
        result(app, "none")
        book(app).tap()
        result(app, "tap:1")
    }
    @MainActor func testOpaqueMenuKeepsTapAndDismissesAfterSelection() {
        let app = XCUIApplication()
        app.launchArguments += ["--hold-slide-ui-test", "--opaque-menu-ui-test"]
        app.launch()
        let source = app.buttons["menu.source"]
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.press(forDuration: 0.7)
        let remove = app.buttons["Remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        result(app, "none")
        XCTAssertFalse(app.buttons["Disabled action"].isEnabled)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Opaque book menu"
        attachment.lifetime = .keepAlways
        add(attachment)
        remove.tap()
        result(app, "menu:remove")
        XCTAssertTrue(remove.waitForNonExistence(timeout: 3))
        source.tap()
        result(app, "menu:tap")
    }

    @MainActor func testHorizontalAndVerticalScrollingDoNotSelect() {
        let app = launch()
        let firstX = book(app).frame.minX
        book(app).swipeLeft(velocity: .slow)
        result(app, "none")
        XCTAssertLessThan(book(app).frame.minX, firstX - 20)
        let row = app.staticTexts["hold.row.0"]
        let firstY = row.frame.minY
        app.otherElements["hold.book.3"].swipeUp(velocity: .slow)
        result(app, "none")
        XCTAssertLessThan(row.frame.minY, firstY - 20)
    }
}
