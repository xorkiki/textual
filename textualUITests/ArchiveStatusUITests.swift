import XCTest

final class ArchiveStatusUITests: XCTestCase {
    @MainActor private func launch() -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--hold-slide-ui-test", "--archive-status-ui-test"]
        app.launch()
        XCTAssertTrue(row(app).waitForExistence(timeout: 10))
        return app
    }
    @MainActor private func row(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["archive.search.archive-fixture"]
    }
    @MainActor private func result(_ app: XCUIApplication, _ expected: String) {
        expectation(for: NSPredicate(format: "label == %@", expected), evaluatedWith: app.staticTexts["archive.result"])
        waitForExpectations(timeout: 3)
    }
    @MainActor func testTapLetsReaderChooseEachStatus() {
        let app = launch()
        for status in ["read", "currently-reading", "to-read", "did-not-finish"] {
            row(app).tap()
            let choice = app.buttons["archive.add.\(status)"]
            XCTAssertTrue(choice.waitForExistence(timeout: 3))
            choice.tap()
            result(app, status)
        }
    }
    @MainActor func testContinuousHoldSlideChoosesEachStatus() {
        let app = launch()
        for (index, status) in ["read", "currently-reading", "to-read", "did-not-finish"].enumerated() {
            let start = row(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let angle = -Double.pi / 2 + (Double(index) / 3 - 0.5) * Double.pi * 0.74
            let end = start.withOffset(CGVector(dx: cos(angle) * 100, dy: sin(angle) * 100))
            start.press(forDuration: 0.45, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.15)
            result(app, status)
        }
    }
    @MainActor func testReleaseOutsideCancelsWithoutAdding() {
        let app = launch()
        let start = row(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.45, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 180)))
        result(app, "none")
        XCTAssertFalse(app.buttons["archive.add.read"].exists)
    }
}
