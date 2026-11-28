import XCTest

/// The Now screen after a stub sign-in, which answers from the shared fixtures.
final class NowUITests: XCTestCase {
    @MainActor
    func testOpensAReviewFromAReviewCard() throws {
        let app = launchSignedIn()
        let title = app.staticTexts["tab-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 30))
        XCTAssertEqual(title.label, "Now")

        let reviews = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", "now-filter", "Reviews")).firstMatch
        XCTAssertTrue(reviews.waitForExistence(timeout: 10), "no Reviews filter")
        // The Released card, second in the list, shows before the filter.
        let released = app.buttons["Reply"].firstMatch
        XCTAssertTrue(released.waitForExistence(timeout: 10), "no Released card before the filter")
        reviews.tap()
        XCTAssertTrue(reviews.isSelected, "the Reviews filter is not marked selected")
        XCTAssertTrue(released.waitForNonExistence(timeout: 5), "the Reviews filter still shows a problem card")
        // On an iPad the sidebar shows too, with the Now count.
        try app.auditAccessibility {
            $0.isUnderBarsContrast || $0.isOnNowFilterCount || $0.isOnCardMonoText || $0.isOnSidebarRow
        }

        let open = app.buttons["Open review"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10), "no Open review button")
        open.tap()

        // The pushed screen has a bar with a way back to Now.
        // Matched by name rather than position: on an iPad the bar's first
        // button can be the sidebar toggle. iOS 26 and later call it
        // "BackButton"; iOS 17 and 18 give it no identifier, only the label
        // "Back" (W2797).
        let isBack = NSPredicate(format: "identifier == %@ OR label == %@", "BackButton", "Back")
        let back = app.navigationBars.buttons.matching(isBack).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "no back button on the pushed screen")
        XCTAssertFalse(open.isHittable, "the Now card is still in front")
    }

    @MainActor
    func testEachKindOfCardShowsItsButtons() throws {
        let app = launchSignedIn()
        XCTAssertTrue(app.staticTexts["tab-title"].waitForExistence(timeout: 30))

        for label in ["Open review", "Reply", "Move to Backlog", "View attempt"] {
            let button = app.buttons[label].firstMatch
            if !button.exists { app.swipeUp() }
            XCTAssertTrue(button.waitForExistence(timeout: 10), "no \(label) button")
        }
    }

    @MainActor
    func testRepliesToAReleasedTask() throws {
        let app = launchSignedIn()
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
        try app.auditAccessibility { issue in issue.isBehindFormSheet }

        send.tap()
        XCTAssertTrue(heading.waitForNonExistence(timeout: 10), "the reply sheet stayed open")
        let notice = app.staticTexts["now-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "no notice after the reply")
        XCTAssertEqual(notice.label, "Reply sent")
    }

    @MainActor
    func testViewAttemptShowsExitCodeAndDurationOnly() throws {
        let app = launchSignedIn()
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
            issue.isBehindFormSheet || (UIDevice.current.userInterfaceIdiom == .pad && issue.isOnAttemptRowValue)
        }

        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(heading.waitForNonExistence(timeout: 10))
    }
}
