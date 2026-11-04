import XCTest

/// Drives the debug Community harness (fixture social transport, in-memory store,
/// no account, no Supabase). Covers load from Open Library like the Discover harness.
final class CommunityUITests: XCTestCase {
    @MainActor private func launch(_ extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["--community-ui-test"] + extra
        app.launch()
        return app
    }

    @MainActor private func waitFor(_ predicate: String, _ element: XCUIElement, timeout: TimeInterval = 5) {
        wait(for: [expectation(for: NSPredicate(format: predicate), evaluatedWith: element)], timeout: timeout)
    }

    @MainActor private func openProfile(_ app: XCUIApplication, _ username: String) {
        app.buttons["community.tab.friends"].tap()
        let row = app.buttons["community.reader.\(username)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(username) is listed")
        row.tap()
        XCTAssertTrue(app.staticTexts["@\(username)"].waitForExistence(timeout: 5), "the reader’s public profile opens")
    }

    @MainActor func testFriendsAndFeedUseTheArchiveTabBar() {
        let app = launch()
        let friends = app.buttons["community.tab.friends"], feed = app.buttons["community.tab.feed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 10))
        waitFor("isSelected == true", feed)
        XCTAssertTrue(app.staticTexts["finished reading and reviewed it"].waitForExistence(timeout: 5),
                      "a finish and its review read as one update")
        XCTAssertTrue(app.staticTexts["saved 2 quotes"].exists, "quotes from one sitting stay together, each kept")
        XCTAssertTrue(app.staticTexts["Fear is a funny thing; it only follows you if you let it lead."].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'like' OR label CONTAINS[c] 'comment'")).firstMatch.exists,
                       "the feed is view-only")

        friends.tap()
        waitFor("isSelected == true", friends)
        XCTAssertTrue(app.buttons["community.accept.eli_reads"].waitForExistence(timeout: 5), "incoming requests can be accepted")
        XCTAssertTrue(app.buttons["community.decline.eli_reads"].exists, "and declined")
        XCTAssertTrue(app.buttons["community.reader.fern"].exists, "sent requests are listed")
        XCTAssertTrue(app.buttons["community.reader.bea"].exists, "friends are listed")
    }

    @MainActor func testAFriendsLibraryCardOpensTheirBooksAndGenres() {
        let app = launch()
        openProfile(app, "bea")
        XCTAssertTrue(app.otherElements["profile.libraryCard"].waitForExistence(timeout: 5), "the existing library card")
        XCTAssertFalse(app.buttons["profile.addFavorites"].exists, "visitors can’t add to the shelf")
        XCTAssertFalse(app.buttons["profile.editShelf"].exists, "or rearrange it")
        let allFriends = app.buttons["profile.allFriends"]
        for _ in 0..<3 where !allFriends.exists { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(allFriends.waitForExistence(timeout: 5), "a compact friends preview sits above the bookshelf")
        allFriends.tap()
        XCTAssertTrue(app.staticTexts["Beatrix"].waitForExistence(timeout: 5), "the full list shows names")
        XCTAssertTrue(app.buttons["profile.addFriend.beatrix"].waitForExistence(timeout: 5),
                      "other readers can be added from the list")
        app.buttons["Close"].firstMatch.tap()
        app.scrollViews.firstMatch.swipeDown()
        let reads = app.buttons["profile.stat.reads"]
        XCTAssertTrue(reads.waitForExistence(timeout: 5))
        reads.tap()
        let sheet = app.scrollViews.firstMatch
        XCTAssertTrue(app.staticTexts["Books read"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Onyx Storm by Rebecca Yarros"].waitForExistence(timeout: 5), "real covers, not a count")
        // Incremental loading: a book from the second page appears after scrolling.
        let later = app.buttons["Onyx Storm (37) by Rebecca Yarros"]
        for _ in 0..<20 where !later.exists { sheet.swipeUp(velocity: .fast) }
        XCTAssertTrue(later.exists, "the list keeps loading beyond the first page")
        app.buttons["Close"].firstMatch.tap()

        let genres = app.buttons["profile.stat.genres"]
        XCTAssertTrue(genres.waitForExistence(timeout: 5))
        genres.tap()
        XCTAssertTrue(app.otherElements["profile.genres"].waitForExistence(timeout: 5) || app.buttons["Fantasy"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: "Genres").count, 1,
                       "the social preview keeps only its top header")
        XCTAssertTrue(app.buttons["Fantasy"].exists, "the Stats genre chart")
        app.buttons["Fantasy"].tap()
        XCTAssertTrue(app.buttons["Onyx Storm by Rebecca Yarros"].waitForExistence(timeout: 5), "a genre opens a cover-only list")
        app.buttons["Close"].firstMatch.tap()
        app.buttons["Close"].firstMatch.tap()

        app.buttons["profile.stat.rereads"].tap()
        XCTAssertTrue(app.staticTexts["Rereads"].waitForExistence(timeout: 5))
    }

    @MainActor func testHiddenStatisticsCannotBeOpened() {
        let app = launch()
        openProfile(app, "cleo")
        let reads = app.buttons["profile.stat.reads"]
        XCTAssertTrue(reads.waitForExistence(timeout: 5), "visible statistics open")
        XCTAssertFalse(app.buttons["profile.stat.genres"].exists, "a hidden statistic is not a control")
        XCTAssertFalse(app.buttons["profile.stat.rereads"].exists)
    }

    @MainActor func testAddingAFriendWaitsForTheServer() {
        let app = launch()
        app.buttons["community.tab.friends"].tap()
        let search = app.textFields["Search by name or username"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("beatrix")
        let control = app.buttons["community.relationship.beatrix"]
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        XCTAssertEqual(control.label, "Add")
        control.tap()
        waitFor("label == 'Sending…'", control, timeout: 2)
        XCTAssertFalse(control.isEnabled, "no duplicate taps while the server decides")
        waitFor("label == 'Requested'", control, timeout: 5)
    }

    @MainActor func testDiscoverFriendsUsesTheExistingCoverGrid() {
        let app = launch(["--community-discover"])
        let tab = app.buttons["discover.tab.friends"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        let page = app.scrollViews["discover.page.friends"]
        let cover = page.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'discover.book.openlibrary:'")).firstMatch
        XCTAssertTrue(cover.waitForExistence(timeout: 10), "friends’ books appear as covers")
        XCTAssertFalse(page.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Onyx'")).firstMatch.exists,
                       "cover-only: no titles, badges, or counts")
    }
}
