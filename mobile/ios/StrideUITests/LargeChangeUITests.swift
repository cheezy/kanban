import XCTest

/// A change too large to approve on a phone, opened from the Review queue
/// after a stub sign-in whose fixtures say `approvable_here` false
/// (`-StrideStubLargeReview`).
final class LargeChangeUITests: XCTestCase {
    private static let arguments = ["-StrideStubLargeReview"]

    /// The notice shows the counts above the verdicts, Approve gives way to
    /// Approve on tablet or web, Request changes stays, and the web button
    /// opens the review on the web, outside the app.
    @MainActor
    func testTheWebButtonOpensTheReviewOnTheWeb() throws {
        let app = launchSignedIn(arguments: Self.arguments)
        openFirstReview(app)

        let notice = app.descendants(matching: .any)["review-large"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "no large-change notice")
        XCTAssertTrue(notice.label.contains("Too large to approve on a phone"), notice.label)
        XCTAssertTrue(notice.label.contains("14 files and 652 changed lines"), notice.label)
        let verdicts = app.descendants(matching: .any)["review-verdicts"].firstMatch
        XCTAssertTrue(verdicts.exists, "no verdicts")
        XCTAssertLessThan(notice.frame.minY, verdicts.frame.minY, "the notice is not above the verdicts")

        XCTAssertFalse(app.buttons["review-approve"].exists, "Approve is still shown")
        let requestChanges = app.buttons["review-request-changes"].firstMatch
        XCTAssertTrue(requestChanges.exists, "no Request changes button")
        XCTAssertTrue(requestChanges.isEnabled, "Request changes is disabled")
        let web = app.buttons["review-approve-elsewhere"].firstMatch
        XCTAssertTrue(web.exists, "no Approve on tablet or web button")
        XCTAssertTrue(web.isEnabled, "Approve on tablet or web is disabled")
        XCTAssertEqual(web.label, "Approve on tablet or web")
        try app.auditAccessibility(ignoringKnownContrast)

        web.tap()

        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        addTeardownBlock { @MainActor in safari.terminate() }
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 30), "the review did not open on the web")
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10), "the app stayed in front")
    }

    /// At the largest text in German the notice's text and the web button fit
    /// without a broken word and pass the audit, Dynamic Type included.
    @MainActor
    func testFitsTheLargestTextInGerman() throws {
        let app = launchSignedIn(
            locale: "de",
            textSize: "UICTContentSizeCategoryAccessibilityXXXL",
            arguments: Self.arguments
        )
        openFirstReview(app, locale: "de")

        let notice = app.descendants(matching: .any)["review-large"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "no large-change notice")
        XCTAssertTrue(notice.label.contains("14 Dateien und 652 geänderte Zeilen"), notice.label)
        for _ in 0..<6 where !notice.isHittable { app.swipeUp() }
        try app.auditAccessibility(ignoringKnownContrast)

        // At this size the review's buttons come after its content.
        let web = app.buttons["review-approve-elsewhere"].firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 10), "no Approve on tablet or web button")
        // Wholly on the screen, not just hittable: on an iPad the audit
        // failed the button's contrast while half of it was still below the
        // screen's edge, once the file list grew to 14 rows (W2801).
        let screen = app.windows.firstMatch.frame
        for _ in 0..<16 where !screen.contains(web.frame) {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)))
        }
        XCTAssertTrue(screen.contains(web.frame), "the web button was not wholly reached")
        XCTAssertTrue(web.isHittable, "the web button cannot be tapped")
        XCTAssertTrue(app.buttons["review-request-changes"].firstMatch.isEnabled, "Request changes is disabled")
        // Dynamic Type and clipped text were checked at the top, where the
        // audit reaches every section, scrolling to those off the screen.
        // Repeated from here, the clipped-text check scrolled back up the
        // 14-file review to the summary's heading and failed it on an iPad
        // on iOS 27.2, though the heading shows whole there (W2801); Dynamic
        // Type is left out as ReviewUITests leaves it out.
        try app.auditAccessibility(skipping: [.dynamicType, .textClipped], ignoringKnownContrast)
    }

    /// The review screen's known issues, as `ReviewUITests` ignores them.
    @MainActor
    private func ignoringKnownContrast(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        issue.isUnderBarsContrast || issue.isOnCardMonoText || issue.isOnSidebarRow || issue.isOnCriteriaTile
            || issue.isOnReviewContrastMisjudgedOnIOS26 || issue.isUnderReviewBottomBar
    }
}
