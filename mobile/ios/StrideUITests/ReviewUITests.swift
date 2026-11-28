import XCTest

/// The review screen, opened from the Review queue after a stub sign-in, which
/// answers from the shared fixtures.
final class ReviewUITests: XCTestCase {
    @MainActor
    func testOpensAFlaggedFileFromTheFilesList() throws {
        // The tiles, the failed note and the flagged file in the design's
        // order, audited in both appearances. Each appearance gets a fresh
        // launch, so the audit never reads a screen still changing colour,
        // as the bar's title once read "nearly passed" mid-change (W2796).
        let appearance = XCUIDevice.shared.appearance
        addTeardownBlock { @MainActor in XCUIDevice.shared.appearance = appearance }
        var app = XCUIApplication()
        for next in [appearance == .dark ? XCUIDevice.Appearance.light : .dark, appearance] {
            XCUIDevice.shared.appearance = next
            app = openReview()
            let passed = app.staticTexts["review-passed"]
            XCTAssertTrue(passed.waitForExistence(timeout: 10), "no verdict count")
            XCTAssertEqual(passed.label, "2 of 4 passed")
            try app.auditAccessibility(ignoringKnownContrast)
        }

        let flagged = app.descendants(matching: .any)["review-file-flagged"].firstMatch
        for _ in 0..<4 where !flagged.isHittable { app.swipeUp() }
        XCTAssertTrue(flagged.waitForExistence(timeout: 10), "no flagged file")
        flagged.tap()

        // The fixtures answer every file with the one diff they hold.
        let path = app.staticTexts["diff-path"]
        XCTAssertTrue(path.waitForExistence(timeout: 10), "the flagged file did not open")
        XCTAssertEqual(path.label, "greeting.ex in lib/example")
    }

    @MainActor
    func testShowsTheSectionsInTheDesignsOrder() throws {
        let app = openReview()

        let ids = ["review-title", "review-summary", "review-verdicts", "review-checks", "review-files"]
        var tops: [CGFloat] = []
        for id in ids {
            let element = app.descendants(matching: .any)[id].firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 10), "no \(id)")
            tops.append(element.frame.minY)
        }
        XCTAssertEqual(tops, tops.sorted(), "the sections are out of order")

        let bar = app.buttons["review-request-changes"]
        XCTAssertTrue(bar.exists, "no bottom bar")
        // Request changes sends nothing yet, so it does not look live.
        XCTAssertFalse(bar.isEnabled, "Request changes is enabled but does nothing")
        let approve = app.buttons["review-approve"].firstMatch
        XCTAssertTrue(approve.waitForExistence(timeout: 10), "no Approve button")
        XCTAssertTrue(approve.isEnabled, "Approve is disabled")
    }

    /// The stub matches the face, so Approve sends the fixtures' approval and
    /// the toast names the tasks the review held up; Next opens the next
    /// review in the queue, whose Approve is live again.
    @MainActor
    func testApprovingShowsTheToastAndNextOpensTheNextReview() throws {
        let app = openReview()

        let approve = app.buttons["review-approve"].firstMatch
        XCTAssertTrue(approve.waitForExistence(timeout: 10), "no Approve button")
        approve.tap()

        let toast = app.descendants(matching: .any)["review-approved-toast"].firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 10), "no Approved toast")
        XCTAssertEqual(app.staticTexts["review-approved"].label, "Approved. W102 and W103 can start.")
        XCTAssertFalse(approve.isEnabled, "Approve is still live after the approval")
        try app.auditAccessibility(ignoringKnownContrast)

        let next = app.buttons["review-next"].firstMatch
        XCTAssertTrue(next.isHittable, "Next cannot be tapped")
        next.tap()

        // The fixtures answer every review alike, so a new review shows as a
        // new model: no toast, and Approve live again.
        XCTAssertTrue(toast.waitForNonExistence(timeout: 10), "the toast stayed after Next")
        let live = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: app.buttons["review-approve"].firstMatch)
        wait(for: [live], timeout: 10)
    }

    /// When the face does not match, the person closes the prompt and the
    /// review stays as it was, with nothing sent.
    @MainActor
    func testAFaceThatDoesNotMatchLeavesTheReviewOpen() throws {
        let app = openReview(arguments: ["-StrideStubApproval", "nomatch"])

        let approve = app.buttons["review-approve"].firstMatch
        XCTAssertTrue(approve.waitForExistence(timeout: 10), "no Approve button")
        approve.tap()

        let toast = app.descendants(matching: .any)["review-approved-toast"].firstMatch
        XCTAssertFalse(toast.waitForExistence(timeout: 3), "a face that did not match approved the review")
        XCTAssertFalse(app.descendants(matching: .any)["review-approve-problem"].firstMatch.exists, "a closed prompt showed a problem")
        XCTAssertTrue(app.staticTexts["review-title"].exists, "the review closed")
        XCTAssertTrue(approve.isEnabled, "Approve is off after a closed prompt")
    }

    /// An approval that cannot be made says why above the buttons, leaves
    /// Approve on, and closes with its button.
    @MainActor
    func testAProblemSaysWhyAndCloses() throws {
        let app = openReview(arguments: ["-StrideStubApproval", "passcode"])

        let approve = app.buttons["review-approve"].firstMatch
        XCTAssertTrue(approve.waitForExistence(timeout: 10), "no Approve button")
        approve.tap()

        let problem = app.staticTexts["review-approve-problem"].firstMatch
        XCTAssertTrue(problem.waitForExistence(timeout: 10), "no problem notice")
        XCTAssertEqual(problem.label, "Set a passcode on this device first. Stride uses it to confirm your approvals.")
        XCTAssertFalse(app.descendants(matching: .any)["review-approved-toast"].firstMatch.exists, "the review was approved")
        XCTAssertTrue(approve.isEnabled, "Approve is off after a problem")
        try app.auditAccessibility(ignoringKnownContrast)

        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.isHittable, "the notice cannot be closed")
        close.tap()
        XCTAssertTrue(problem.waitForNonExistence(timeout: 5), "the notice stayed after Close")
    }

    /// At the largest text size the audit has no larger size to push the
    /// sections under a bar with, and the buttons follow the files instead
    /// of being pinned, so the whole review is audited without
    /// `isUnderReviewBottomBar`: clipped text anywhere on the screen, the
    /// buttons too, fails here. The audit reaches every section by itself,
    /// scrolling the screen as it goes, so it runs once at the top and once
    /// at the end, where the buttons are.
    @MainActor
    func testFitsTheLargestText() throws {
        let app = openReview(textSize: "UICTContentSizeCategoryAccessibilityXXXL")

        try app.auditAccessibility(ignoringKnownIssuesWithoutBar)
        // Not pinned over the content: the buttons come after the files.
        let approve = app.buttons["review-approve"].firstMatch
        XCTAssertTrue(approve.exists, "no Approve button")
        XCTAssertFalse(approve.isHittable, "the buttons are pinned over the review at the largest text")
        for _ in 0..<16 where !approve.isHittable {
            // Most of the screen at a time; a plain swipe moved it a few lines.
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)))
        }
        XCTAssertTrue(approve.isHittable, "the Approve button after the files was not reached")
        let files = app.descendants(matching: .any)["review-files"].firstMatch
        XCTAssertLessThanOrEqual(files.frame.maxY, approve.frame.minY, "the buttons are not after the files")
        // Dynamic Type was checked at the top; repeating it here ran past
        // the audit's time limit.
        try app.auditAccessibility(skipping: .dynamicType, ignoringKnownIssuesWithoutBar)
    }

    /// The short mono identifier and the content under the bars, as the Now
    /// and Shell tests ignore them, the acceptance tile's mono count, the
    /// elements iOS 26 misjudges, and text under the review's bottom bar;
    /// the rest is audited.
    @MainActor
    private func ignoringKnownContrast(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        ignoringKnownIssuesWithoutBar(issue) || issue.isUnderReviewBottomBar
    }

    /// The same, without `isUnderReviewBottomBar`, for the largest text,
    /// where no bar is pinned over the content.
    @MainActor
    private func ignoringKnownIssuesWithoutBar(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        issue.isUnderBarsContrast || issue.isOnCardMonoText || issue.isOnSidebarRow || issue.isOnCriteriaTile
            || issue.isOnReviewContrastMisjudgedOnIOS26
    }

    @MainActor
    private func openReview(textSize: String? = nil, arguments: [String] = []) -> XCUIApplication {
        let app = launchSignedIn(textSize: textSize, arguments: arguments)
        openFirstReview(app)

        XCTAssertTrue(app.staticTexts["review-title"].waitForExistence(timeout: 10), "the review did not open")
        return app
    }
}
