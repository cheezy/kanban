import XCTest

/// The Now screen after a stub sign-in, which answers from the shared fixtures.
final class NowUITests: XCTestCase {
    @MainActor
    func testOpensAReviewFromAReviewCard() throws {
        let app = signIn()
        let title = app.staticTexts["tab-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 30))
        XCTAssertEqual(title.label, "Now")

        let reviews = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", "now-filter", "Reviews")).firstMatch
        XCTAssertTrue(reviews.waitForExistence(timeout: 10), "no Reviews filter")
        reviews.tap()
        XCTAssertTrue(reviews.isSelected, "the Reviews filter is not marked selected")
        XCTAssertFalse(app.buttons["View attempt"].exists, "the Reviews filter still shows a problem card")
        // On an iPad the sidebar shows too, with the Now count.
        try app.auditAccessibility {
            $0.isUnderBarsContrast || $0.isOnNowFilterCount || $0.isOnCardMonoText || $0.isOnSidebarRow
        }

        let open = app.buttons["Open review"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10), "no Open review button")
        open.tap()

        // The pushed screen has a bar with a way back to Now.
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "no back button on the pushed screen")
        XCTAssertFalse(open.isHittable, "the Now card is still in front")
    }

    @MainActor
    func testEachKindOfCardShowsItsButtons() throws {
        let app = signIn()
        XCTAssertTrue(app.staticTexts["tab-title"].waitForExistence(timeout: 30))

        for label in ["Open review", "Reply", "Move to Backlog", "View attempt"] {
            let button = app.buttons[label].firstMatch
            if !button.exists { app.swipeUp() }
            XCTAssertTrue(button.waitForExistence(timeout: 10), "no \(label) button")
        }
    }

    @MainActor
    func testRepliesToAReleasedTask() throws {
        let app = signIn()
        XCTAssertTrue(app.staticTexts["tab-title"].waitForExistence(timeout: 30))

        let reply = app.buttons["Reply"].firstMatch
        if !reply.exists { app.swipeUp() }
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "no Reply button")
        reply.tap()

        let heading = app.staticTexts["sheet-title"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        XCTAssertEqual(heading.label, "Reply")
        let send = app.buttons["reply-send"]
        XCTAssertFalse(send.isEnabled, "an empty reply can be sent")

        let field = app.textViews["reply-text"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no reply field")
        field.tap()
        field.typeText("Keep the old column for now.")
        XCTAssertTrue(send.isEnabled, "a reply cannot be sent")
        try app.auditAccessibility(ignoringFormSheetBackdrop)

        send.tap()
        XCTAssertTrue(heading.waitForNonExistence(timeout: 10), "the reply sheet stayed open")
        let notice = app.staticTexts["now-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "no notice after the reply")
        XCTAssertEqual(notice.label, "Reply sent")
    }

    @MainActor
    func testViewAttemptShowsExitCodeAndDurationOnly() throws {
        let app = signIn()
        XCTAssertTrue(app.staticTexts["tab-title"].waitForExistence(timeout: 30))

        let view = app.buttons["View attempt"].firstMatch
        for _ in 0..<3 where !view.isHittable { app.swipeUp() }
        XCTAssertTrue(view.waitForExistence(timeout: 10), "no View attempt button")
        view.tap()

        let heading = app.staticTexts["sheet-title"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        XCTAssertEqual(heading.label, "Last after_goal attempt")
        let exitCode = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Exit code")).firstMatch
        XCTAssertTrue(exitCode.waitForExistence(timeout: 10), "no exit code")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Duration")).firstMatch.exists)
        // The hook's output is never on the phone, so there is nothing to open.
        XCTAssertFalse(app.buttons["View log"].exists)
        try app.auditAccessibility { issue in
            self.ignoringFormSheetBackdrop(issue) || (UIDevice.current.userInterfaceIdiom == .pad && issue.isOnAttemptRowValue)
        }

        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(heading.waitForNonExistence(timeout: 10))
    }

    /// On an iPad the form sheet leaves the Now screen visible, dimmed and out
    /// of VoiceOver's reach, around it, and the audit reports that text as
    /// "potentially inaccessible text" with no element, as `ShellUITests`
    /// notes for the corner sheets. Only that is ignored.
    @MainActor
    private func ignoringFormSheetBackdrop(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        UIDevice.current.userInterfaceIdiom == .pad && issue.auditType == .elementDetection && issue.element == nil
    }

    @MainActor
    private func signIn() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-StrideStubSignIn", "allow", "-AppleLanguages", "(en)"]
        app.launch()

        let signIn = app.buttons["Sign in"].firstMatch
        XCTAssertTrue(signIn.waitForExistence(timeout: 30))
        signIn.tap()
        XCTAssertTrue(signIn.waitForNonExistence(timeout: 30))

        return app
    }
}
