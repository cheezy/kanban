import XCTest

/// The file screen, opened from a review's flagged file after a stub sign-in,
/// which answers from the shared fixtures: every file shows the one diff they
/// hold, `lib/example/greeting.ex`.
final class DiffUITests: XCTestCase {
    @MainActor
    func testVoiceOverReadsAddedAndRemovedLines() throws {
        let app = openFile()

        let lines = app.descendants(matching: .any).matching(identifier: "diff-line")
        XCTAssertTrue(lines.firstMatch.waitForExistence(timeout: 10), "no diff lines")
        let labels = lines.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(labels.contains("Added, line 2"), "no added line in \(labels)")
        XCTAssertTrue(labels.contains("Removed, line 2"), "no removed line in \(labels)")
        XCTAssertTrue(labels.contains("Line 1"), "no unchanged line in \(labels)")
        // The text follows as the value, so the marker is never read alone.
        XCTAssertFalse(app.staticTexts["−"].exists, "the removed line's marker is read on its own")
        XCTAssertFalse(app.staticTexts["+"].exists, "an added line's marker is read on its own")
        let added = lines.matching(NSPredicate(format: "label == %@", "Added, line 2")).firstMatch
        XCTAssertEqual(added.value as? String, "  # Greets one person")

        let note = app.descendants(matching: .any)["diff-note"].firstMatch
        XCTAssertTrue(note.exists, "no note in the diff")
        XCTAssertEqual(note.label, "Security reviewer: Interpolates input into a greeting without a length limit.")
        let line3 = lines.matching(NSPredicate(format: "label == %@", "Added, line 3")).firstMatch
        XCTAssertEqual(line3.frame.maxY, note.frame.minY, accuracy: 2, "the note is not under its line")
    }

    @MainActor
    func testShowsTheHeaderAndAuditsBothAppearances() throws {
        // A fresh launch for each appearance, so the audit never reads a
        // screen still changing colour (W2796).
        let appearance = XCUIDevice.shared.appearance
        addTeardownBlock { @MainActor in XCUIDevice.shared.appearance = appearance }
        for next in [appearance == .dark ? XCUIDevice.Appearance.light : .dark, appearance] {
            XCUIDevice.shared.appearance = next
            let app = openFile()

            XCTAssertEqual(app.staticTexts["diff-position"].label, "1 of 3")
            XCTAssertEqual(app.staticTexts["diff-language"].label, "Elixir")
            XCTAssertEqual(app.descendants(matching: .any)["diff-counts"].firstMatch.label, "3 lines added and 1 line removed")
            XCTAssertTrue(app.descendants(matching: .any)["diff-flagged"].firstMatch.exists, "the file is not flagged")
            XCTAssertEqual(app.descendants(matching: .any)["diff-file-note"].firstMatch.label, "Reviewer: The file has no tests yet.")
            try app.auditAccessibility(ignoringKnownIssues)
        }
    }

    @MainActor
    func testNextFileAndASwipePageThroughTheFiles() throws {
        let app = openFile()
        let position = app.staticTexts["diff-position"]

        app.buttons["diff-next"].tap()
        XCTAssertTrue(waitFor(position, label: "2 of 3"), "Next file did not show the second file")

        // The image has no diff, so the next file wraps to the flagged one.
        app.descendants(matching: .any)["diff-code"].firstMatch.swipeLeft()
        XCTAssertTrue(waitFor(position, label: "1 of 3"), "a swipe did not wrap to the first flagged file")

        app.descendants(matching: .any)["diff-code"].firstMatch.swipeRight()
        XCTAssertTrue(waitFor(position, label: "2 of 3"), "a swipe back did not show the previous file")

        app.buttons["diff-back"].tap()
        XCTAssertTrue(app.staticTexts["review-title"].waitForExistence(timeout: 10), "Back to verdicts did not return")
    }

    /// A fast flick that starts on the code scrolls the screen. A slow drag
    /// scrolled even while the sideways swipe held up every fast flick, and so
    /// did a drag at XCUI's `.fast`; the flick here runs at 5000 points a
    /// second, which the old swipe stopped dead (W2797).
    @MainActor
    func testAFastFlickOnTheCodeScrolls() throws {
        let app = openFile(textSize: "UICTContentSizeCategoryAccessibilityXXXL")
        let code = app.descendants(matching: .any)["diff-code"].firstMatch
        let position = app.staticTexts["diff-position"]
        let window = app.windows.firstMatch.frame
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        XCTAssertTrue(code.frame.contains(start.screenPoint), "the flick does not start on the code")
        let before = position.frame.minY

        start.press(forDuration: 0, thenDragTo: end, withVelocity: XCUIGestureVelocity(5000), thenHoldForDuration: 0)

        XCTAssertLessThan(position.frame.minY, before - window.height * 0.3, "a fast flick on the code did not scroll")
    }

    /// At the largest text, in German, where labels run longest, the buttons
    /// follow the diff instead of being pinned over it, and every line wraps.
    @MainActor
    func testFitsTheLargestTextInGerman() throws {
        let app = openFile(locale: "de", textSize: "UICTContentSizeCategoryAccessibilityXXXL")

        try app.auditAccessibility(ignoringKnownIssues)
        let back = app.buttons["diff-back"]
        XCTAssertTrue(back.exists, "no Back to verdicts button")
        let code = app.descendants(matching: .any)["diff-code"].firstMatch
        app.scroll(untilHittable: back, to: 0.1)
        XCTAssertTrue(back.isHittable, "the buttons after the diff were not reached")
        XCTAssertLessThanOrEqual(code.frame.maxY, back.frame.minY, "the buttons are not after the diff")
        try app.auditAccessibility(skipping: .dynamicType, ignoringKnownIssues)
    }

    /// The content under the bars, which iOS fades on purpose, and an
    /// iPad sidebar row, as the other screens' tests ignore them, the
    /// title, which is the file's name, and the flagged pill, a diff line on
    /// an iPad and the bar's buttons on iOS 26, whose contrast the audit
    /// misjudges.
    @MainActor
    private func ignoringKnownIssues(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        issue.isUnderBarsContrast || issue.isOnSidebarRow || issue.isFileNameTitle || issue.isOnFlaggedPill
            || issue.isOnDiffLineOnIPad || issue.isOnReviewContrastMisjudgedOnIOS26
    }

    @MainActor
    private func waitFor(_ element: XCUIElement, label: String) -> Bool {
        let matches = NSPredicate(format: "label == %@", label)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: matches, object: element)], timeout: 10) == .completed
    }

    @MainActor
    private func openFile(locale: String = "en", textSize: String? = nil) -> XCUIApplication {
        let app = launchSignedIn(locale: locale, textSize: textSize)
        openFirstReview(app, locale: locale)

        let flagged = app.descendants(matching: .any)["review-file-flagged"].firstMatch
        XCTAssertTrue(flagged.waitForExistence(timeout: 10), "no flagged file")
        app.scroll(untilHittable: flagged)
        flagged.tap()

        XCTAssertTrue(app.descendants(matching: .any)["diff-code"].firstMatch.waitForExistence(timeout: 10), "the file did not open")
        return app
    }
}
