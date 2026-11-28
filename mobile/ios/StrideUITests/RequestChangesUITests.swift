import XCTest

/// Request changes from the review screen, opened from the Review queue after
/// a stub sign-in, which answers from the shared fixtures.
final class RequestChangesUITests: XCTestCase {
    /// The sheet opens with Send off, a chip adds the failed verdict's note,
    /// Send shows the Changes requested toast with decision 10's copy, and
    /// Next opens the next review, whose Request changes is live again.
    @MainActor
    func testRequestsChangesFromAReview() throws {
        let app = launchSignedIn()
        openFirstReview(app)
        XCTAssertTrue(app.staticTexts["review-title"].waitForExistence(timeout: 10), "the review did not open")

        let requestChanges = app.buttons["review-request-changes"].firstMatch
        XCTAssertTrue(requestChanges.waitForExistence(timeout: 10), "no Request changes button")
        XCTAssertTrue(requestChanges.isEnabled, "Request changes is disabled")
        requestChanges.tap()

        let title = app.staticTexts["sheet-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the sheet did not open")
        XCTAssertEqual(title.label, "Request changes")
        let send = app.buttons["changes-send"].firstMatch
        XCTAssertFalse(send.isEnabled, "Send is enabled with no text")
        XCTAssertEqual(
            app.staticTexts["changes-footnote"].label,
            "Claude gets this note. The task stays in Review until the changes are picked up."
        )
        try app.auditAccessibility(ignoringSheetIssues)

        let chip = app.buttons["changes-add-patterns"].firstMatch
        XCTAssertTrue(chip.exists, "no chip for the failed Patterns verdict")
        XCTAssertEqual(chip.label, "Add the Patterns finding")
        chip.tap()
        let text = app.textViews["changes-text"].firstMatch
        XCTAssertEqual(text.value as? String, "One view model reads the store directly.")
        XCTAssertFalse(chip.isEnabled, "the chip can add its note twice")
        XCTAssertTrue(send.isEnabled, "Send is disabled with text")
        // The used chip reads in ink-3, which must still reach 4.5:1.
        try app.auditAccessibility(ignoringSheetIssues)
        send.tap()

        let toast = app.descendants(matching: .any)["review-changes-toast"].firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 10), "no Changes requested toast")
        XCTAssertFalse(title.exists, "the sheet stayed open")
        XCTAssertEqual(
            app.staticTexts["review-changes-requested"].label,
            "Changes requested. W101 is waiting for Claude to pick up the changes."
        )
        XCTAssertFalse(requestChanges.isEnabled, "Request changes is still live after the request")
        try app.auditAccessibility(ignoringKnownContrast)

        let next = app.buttons["review-next"].firstMatch
        XCTAssertTrue(next.isHittable, "Next cannot be tapped")
        next.tap()

        // The fixtures answer every review alike, so a new review shows as a
        // new model: no toast, and Request changes live again.
        XCTAssertTrue(toast.waitForNonExistence(timeout: 10), "the toast stayed after Next")
        let live = expectation(
            for: NSPredicate(format: "isEnabled == true"),
            evaluatedWith: app.buttons["review-request-changes"].firstMatch
        )
        wait(for: [live], timeout: 10)
    }

    /// At the largest text in German, where labels run longest, the sheet
    /// stacks its title, Cancel and Send each on its own line, both can be
    /// tapped, neither label wraps, and it passes the audit, Dynamic Type
    /// included.
    @MainActor
    func testFitsTheLargestTextInGerman() throws {
        let app = launchSignedIn(locale: "de", textSize: "UICTContentSizeCategoryAccessibilityXXXL")
        openFirstReview(app, locale: "de")
        XCTAssertTrue(app.staticTexts["review-title"].waitForExistence(timeout: 10), "the review did not open")

        // At this size the review's buttons come after its content.
        let requestChanges = app.buttons["review-request-changes"].firstMatch
        XCTAssertTrue(requestChanges.waitForExistence(timeout: 10), "no Request changes button")
        for _ in 0..<16 where !requestChanges.isHittable {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)))
        }
        XCTAssertTrue(requestChanges.isHittable, "the Request changes button was not reached")
        requestChanges.tap()

        let title = app.staticTexts["sheet-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the sheet did not open")
        XCTAssertEqual(title.label, "Änderungen anfordern")
        let cancel = app.buttons["changes-cancel"].firstMatch
        let send = app.buttons["changes-send"].firstMatch
        XCTAssertTrue(cancel.isHittable, "Cancel cannot be tapped")
        XCTAssertTrue(send.isHittable, "Send cannot be tapped")
        XCTAssertLessThanOrEqual(title.frame.maxY, cancel.frame.minY, "the title is not above Cancel and Send")
        // Each on its own line, so neither word breaks: side by side on an
        // iPhone, "Abbrechen" broke onto a second line and stood taller than
        // Send.
        XCTAssertLessThanOrEqual(cancel.frame.maxY, send.frame.minY, "Cancel and Send share a line")
        XCTAssertEqual(cancel.frame.height, send.frame.height, accuracy: 1, "Cancel's label wraps")
        try app.auditAccessibility(ignoringSheetIssues)

        // An iPad's form sheet is shorter than the screen, so what lies past
        // its edge above is audited once scrolled into view: the chip, then
        // the rest of the sheet down to its footnote, the dictation hint
        // between them.
        let sheet = app.scrollViews.containing(.staticText, identifier: "sheet-title").firstMatch
        for target in [app.buttons["changes-add-patterns"].firstMatch, app.staticTexts["changes-footnote"]] {
            scroll(target, intoView: sheet)
            try app.auditAccessibility(skipping: .dynamicType, ignoringSheetIssues)
        }
    }

    /// Drags the sheet up until `element` is wholly inside it. The field
    /// covers the sheet's middle and scrolls on its own, so the drag runs in
    /// the sheet's left margin.
    @MainActor
    private func scroll(_ element: XCUIElement, intoView sheet: XCUIElement) {
        for _ in 0..<8 where !sheet.frame.contains(element.frame) {
            let start = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.9))
            start.press(forDuration: 0.05, thenDragTo: sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.3)))
        }
        XCTAssertTrue(sheet.frame.contains(element.frame), "\(element.identifier) was not scrolled into view")
    }

    /// Cancel closes the sheet and sends nothing.
    @MainActor
    func testCancelSendsNothing() throws {
        let app = launchSignedIn()
        openFirstReview(app)

        let requestChanges = app.buttons["review-request-changes"].firstMatch
        XCTAssertTrue(requestChanges.waitForExistence(timeout: 10), "no Request changes button")
        requestChanges.tap()
        let title = app.staticTexts["sheet-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the sheet did not open")
        app.buttons["changes-add-patterns"].firstMatch.tap()

        app.buttons["changes-cancel"].firstMatch.tap()

        XCTAssertTrue(title.waitForNonExistence(timeout: 10), "Cancel did not close the sheet")
        XCTAssertFalse(app.descendants(matching: .any)["review-changes-toast"].exists, "Cancel sent the notes")
        XCTAssertTrue(requestChanges.isEnabled, "Request changes is off after Cancel")
    }

    /// The sheet's known issues: the iPad's dimmed screen behind it, its
    /// content scrolled past its edge, and the card text behind it.
    @MainActor
    private func ignoringSheetIssues(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        issue.isBehindFormSheet || issue.isPastSheetEdge || issue.isOnCardMonoText
    }

    /// The review screen's known issues, as `ReviewUITests` ignores them.
    @MainActor
    private func ignoringKnownContrast(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        issue.isUnderBarsContrast || issue.isOnCardMonoText || issue.isOnSidebarRow || issue.isOnCriteriaTile
            || issue.isOnReviewContrastMisjudgedOnIOS26 || issue.isUnderReviewBottomBar
    }
}
