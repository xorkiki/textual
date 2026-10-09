import XCTest

/// Exercises only local navigation and validation. Never submits an account or sends email.
final class TextualAuthUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCreateAccountValidationAndDraftSurviveBackNavigation() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        defer { attachScreenshot("Account flow — stopped before account creation", app: app) }

        let createAccount = app.buttons["welcome.createAccount"]
        XCTAssertTrue(createAccount.waitForExistence(timeout: 15), "Run this test on a signed-out simulator. The test never signs out an existing account or changes authentication state.")
        XCTAssertTrue(app.buttons["welcome.signIn"].exists)
        createAccount.tap()

        let email = app.textFields["auth.email"]
        waitUntilHittable(email)
        email.tap()
        email.typeText("not-an-email")
        tap("auth.next", in: app)
        assertLocalError("valid email", in: app)
        XCTAssertTrue(email.exists, "Invalid email must remain on the email question.")

        replaceText(in: email, with: "reader@example.invalid", existingCharacterCount: 12)
        tap("auth.next", in: app)
        let password = app.secureTextFields["auth.password"]
        waitUntilHittable(password)
        password.tap()
        password.typeText("short")
        tap("auth.next", in: app)
        assertLocalError("8 characters", in: app)
        XCTAssertTrue(password.exists, "A short password must not advance the flow.")

        let testPassword = "BookishTestPassword9"
        replaceText(in: password, with: testPassword, existingCharacterCount: 5)
        tap("auth.next", in: app)
        let firstName = app.textFields["auth.firstName"]
        waitUntilHittable(firstName)
        firstName.tap()
        firstName.typeText("Jordan")
        tap("auth.next", in: app)
        XCTAssertTrue(app.textFields["auth.username"].waitForExistence(timeout: 5))

        // Back must restore the actual draft, including the password, not rebuild blank screens.
        tap("auth.back", in: app)
        XCTAssertTrue(firstName.waitForExistence(timeout: 5))
        XCTAssertEqual(firstName.value as? String, "Jordan")
        tap("auth.back", in: app)
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        tap("account.passwordVisibility", in: app)
        let revealedPassword = app.textFields["auth.password"]
        XCTAssertTrue(revealedPassword.waitForExistence(timeout: 5))
        XCTAssertEqual(revealedPassword.value as? String, testPassword)
        tap("account.passwordVisibility", in: app)
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        tap("auth.back", in: app)
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        XCTAssertEqual(email.value as? String, "reader@example.invalid")

        // Continue the retained draft to the final question, then deliberately stop.
        tap("auth.next", in: app)
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        tap("auth.next", in: app)
        XCTAssertTrue(firstName.waitForExistence(timeout: 5))
        XCTAssertEqual(firstName.value as? String, "Jordan")
        tap("auth.next", in: app)
        let username = app.textFields["auth.username"]
        waitUntilHittable(username)
        username.tap()
        username.typeText("reader_notes")
        XCTAssertTrue(app.buttons["auth.submit"].exists)
        XCTAssertEqual(username.value as? String, "reader_notes")
        XCTAssertFalse(app.staticTexts["Creating your account…"].exists)
        // Do not tap auth.submit: this test must not create a user or send confirmation email.
    }

    @MainActor
    func testSignInAndForgotPasswordNavigationDoesNotSendEmail() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        defer {
            attachScreenshot("Password reset — stopped before sending email", app: app)
            XCUIDevice.shared.orientation = .portrait
        }

        let signIn = app.buttons["welcome.signIn"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 15), "This navigation test requires a signed-out simulator.")
        signIn.tap()
        let email = app.textFields["auth.email"]
        waitUntilHittable(email)
        email.tap()
        email.typeText("reader@example.invalid")
        tap("auth.next", in: app)
        XCTAssertTrue(app.secureTextFields["auth.password"].waitForExistence(timeout: 5))
        scrollToReveal(app.buttons["auth.forgotPassword"], in: app.scrollViews["auth.content"])
        tap("auth.forgotPassword", in: app)
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        XCTAssertEqual(email.value as? String, "reader@example.invalid")
        XCTAssertTrue(app.buttons["auth.submit"].exists)
        tap("auth.back", in: app)
        XCTAssertTrue(app.secureTextFields["auth.password"].waitForExistence(timeout: 5))

        // The landscape keyboard leaves very little vertical space. The pinned action
        // must reduce the scroll viewport so it cannot intercept taps on its content.
        XCUIDevice.shared.orientation = .landscapeLeft
        let scroll = app.scrollViews["auth.content"]
        let submit = app.buttons["auth.submit"]
        let layout = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width > app.frame.height
                && scroll.exists && submit.exists
                && scroll.frame.height > 0
                && scroll.frame.maxY <= submit.frame.minY + 1
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [layout], timeout: 5), .completed,
                       "The account footer must not cover the scrolling questions in landscape.")
        // No sign-in, reset, or signup request is submitted.
    }

    @MainActor
    func testConfirmationCodeCanBeEnteredWithoutCreatingAnAccountOrSendingEmail() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        defer { attachScreenshot("Confirmation code — local validation only", app: app) }

        let signIn = app.buttons["welcome.signIn"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 15), "This navigation test requires a signed-out simulator.")
        signIn.tap()
        let email = app.textFields["auth.email"]
        waitUntilHittable(email)
        scrollToReveal(app.buttons["auth.haveConfirmationCode"], in: app.scrollViews["auth.content"])
        tap("auth.haveConfirmationCode", in: app)
        assertLocalError("valid email", in: app)
        XCTAssertFalse(app.textFields["auth.emailCode"].exists)

        scrollToReveal(email, in: app.scrollViews["auth.content"])
        email.tap()
        email.typeText("reader@example.invalid")
        scrollToReveal(app.buttons["auth.haveConfirmationCode"], in: app.scrollViews["auth.content"])
        tap("auth.haveConfirmationCode", in: app)
        let code = app.textFields["auth.emailCode"]
        waitUntilHittable(code)
        XCTAssertTrue(app.buttons["auth.resendCode"].exists)

        // Empty and short codes are rejected locally; never submit a valid-length code.
        tap("auth.submit", in: app)
        assertLocalError("code from your email", in: app)
        scrollToReveal(code, in: app.scrollViews["auth.content"])
        code.tap()
        code.typeText("123")
        tap("auth.submit", in: app)
        assertLocalError("code from your email", in: app)
        XCTAssertTrue(code.exists)
        XCTAssertEqual(code.value as? String, "123")

        tap("auth.back", in: app)
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        XCTAssertEqual(email.value as? String, "reader@example.invalid")
        XCTAssertFalse(code.exists)
        scrollToReveal(app.buttons["auth.haveConfirmationCode"], in: app.scrollViews["auth.content"])
        tap("auth.haveConfirmationCode", in: app)
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        XCTAssertNotEqual(code.value as? String, "123", "Returning to code entry must clear the previous code.")
        // Never tap auth.resendCode, and never submit a real or valid-length code.
    }

    @MainActor
    func testRecoveryCodeCanBeEnteredWithoutRequestingAnotherEmail() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        defer { attachScreenshot("Recovery code — local validation only", app: app) }

        let signIn = app.buttons["welcome.signIn"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 15), "This navigation test requires a signed-out simulator.")
        signIn.tap()
        let email = app.textFields["auth.email"]
        waitUntilHittable(email)
        email.tap()
        email.typeText("reader@example.invalid")
        tap("auth.next", in: app)
        XCTAssertTrue(app.secureTextFields["auth.password"].waitForExistence(timeout: 5))
        scrollToReveal(app.buttons["auth.forgotPassword"], in: app.scrollViews["auth.content"])
        tap("auth.forgotPassword", in: app)
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        XCTAssertEqual(email.value as? String, "reader@example.invalid")
        scrollToReveal(app.buttons["auth.haveRecoveryCode"], in: app.scrollViews["auth.content"])
        tap("auth.haveRecoveryCode", in: app)

        let code = app.textFields["auth.emailCode"]
        waitUntilHittable(code)
        XCTAssertTrue(app.buttons["auth.resendCode"].exists)
        tap("auth.submit", in: app)
        assertLocalError("code from your email", in: app)
        scrollToReveal(code, in: app.scrollViews["auth.content"])
        code.tap()
        code.typeText("123")
        tap("auth.submit", in: app)
        assertLocalError("code from your email", in: app)
        XCTAssertTrue(code.exists)
        XCTAssertFalse(app.secureTextFields["auth.confirmPassword"].exists,
                       "An invalid local code must not enter password recovery.")

        tap("auth.back", in: app)
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        XCTAssertEqual(email.value as? String, "reader@example.invalid")
        XCTAssertFalse(code.exists)
        scrollToReveal(app.buttons["auth.haveRecoveryCode"], in: app.scrollViews["auth.content"])
        tap("auth.haveRecoveryCode", in: app)
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        XCTAssertNotEqual(code.value as? String, "123", "Returning to code entry must clear the previous code.")
        // Entering this route and pressing Back must not request or resend email.
    }

    @MainActor
    private func tap(_ identifier: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[identifier]
        waitUntilHittable(button, file: file, line: line)
        button.tap()
    }

    @MainActor
    private func scrollToReveal(_ element: XCUIElement, in scrollView: XCUIElement,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(scrollView.waitForExistence(timeout: 5), file: file, line: line)
        // Scroll within the keyboard-sized viewport instead of tapping through
        // the pinned footer. Either direction may be needed after showing an error.
        for _ in 0..<4 {
            if element.exists && element.isHittable && scrollView.frame.contains(element.frame) { return }
            if element.exists && element.frame.minY < scrollView.frame.minY {
                scrollView.swipeDown()
            } else {
                scrollView.swipeUp()
            }
        }
        waitUntilHittable(element, file: file, line: line)
        XCTAssertTrue(scrollView.frame.contains(element.frame),
                      "The control must be inside the scrolling viewport before tapping.",
                      file: file, line: line)
    }

    @MainActor
    private func waitUntilHittable(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, file: file, line: line)
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with replacement: String, existingCharacterCount: Int) {
        // These test strings are shorter than the field width; tapping its trailing edge
        // places the cursor at the end without relying on localized selection menus.
        let trailingEdge = field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        trailingEdge.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existingCharacterCount) + replacement)
    }

    @MainActor
    private func assertLocalError(_ text: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let error = app.descendants(matching: .any).matching(identifier: "auth.error").firstMatch
        scrollToReveal(error, in: app.scrollViews["auth.content"], file: file, line: line)
        XCTAssertTrue(error.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(error.label.localizedCaseInsensitiveContains(text), "Unexpected validation text: \(error.label)", file: file, line: line)
    }

    @MainActor
    private func attachScreenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
