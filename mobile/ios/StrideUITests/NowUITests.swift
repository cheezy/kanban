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
