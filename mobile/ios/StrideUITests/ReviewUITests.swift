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

        let path = app.staticTexts["review-file-path"]
        XCTAssertTrue(path.waitForExistence(timeout: 10), "the flagged file did not open")
        XCTAssertEqual(path.label, "mobile/ios/Stride/SignIn/SignInView.swift")
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
    private func openReview(textSize: String? = nil) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-StrideStubSignIn", "allow", "-AppleLanguages", "(en)"]
        if let textSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", textSize]
        }
        app.launch()

        let signIn = app.buttons["Sign in"].firstMatch
        XCTAssertTrue(signIn.waitForExistence(timeout: 30))
        signIn.tap()
        XCTAssertTrue(signIn.waitForNonExistence(timeout: 30))

        let tab = reviewTab(app)
        XCTAssertTrue(tab.waitForExistence(timeout: 30), "no Review tab")
        tab.tap()

        let row = app.buttons["review-open"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no review in the queue")
        row.tap()

        XCTAssertTrue(app.staticTexts["review-title"].waitForExistence(timeout: 10), "the review did not open")
        return app
    }

    /// The tab bar item on a phone and the sidebar row on an iPad.
    @MainActor
    private func reviewTab(_ app: XCUIApplication) -> XCUIElement {
        if UIDevice.current.userInterfaceIdiom == .pad {
            let row = NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", "sidebar-tab", "Review")
            return app.descendants(matching: .any).matching(row).firstMatch
        }
        return app.tabBars.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Review")).firstMatch
    }
}
