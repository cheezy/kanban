import XCTest

extension XCTestCase {
    /// Launches the app with the stub sign-in, in the given language and
    /// text size, and taps Sign in, which the stub always allows. The screens
    /// after it answer from the shared fixtures.
    @MainActor
    func launchSignedIn(locale: String = "en", textSize: String? = nil) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-StrideStubSignIn", "allow", "-AppleLanguages", "(\(locale))"]
        if let textSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", textSize]
        }
        app.launch()

        let signIn = app.buttons[locale == "de" ? "Anmelden" : "Sign in"].firstMatch
        XCTAssertTrue(signIn.waitForExistence(timeout: 30))
        signIn.tap()
        XCTAssertTrue(signIn.waitForNonExistence(timeout: 30))
        return app
    }

    /// Opens the Review tab and the first review in its queue.
    @MainActor
    func openFirstReview(_ app: XCUIApplication, locale: String = "en") {
        let tab = app.tabControl(locale == "de" ? "Überprüfung" : "Review")
        XCTAssertTrue(tab.waitForExistence(timeout: 30), "no Review tab")
        tab.tap()

        let row = app.buttons["review-open"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no review in the queue")
        row.tap()
    }
}

extension XCUIApplication {
    /// A tab by the start of its label, which may carry a badge: the tab bar
    /// item on a phone, and on an iPad the sidebar row, a button the shell
    /// marks `sidebar-tab`.
    @MainActor
    func tabControl(_ label: String) -> XCUIElement {
        let starts = NSPredicate(format: "label BEGINSWITH %@", label)
        if UIDevice.current.userInterfaceIdiom == .pad {
            let row = NSCompoundPredicate(andPredicateWithSubpredicates: [NSPredicate(format: "identifier == %@", "sidebar-tab"), starts])
            return descendants(matching: .any).matching(row).firstMatch
        }
        return tabBars.buttons.matching(starts).firstMatch
    }

    /// Drags the screen up from three quarters of its height to `end` until
    /// `element` can be hit, sixteen drags at most. A press and a drag moves
    /// a set distance, where `swipeUp()` can fling past the element.
    func scroll(untilHittable element: XCUIElement, to end: CGFloat = 0.25) {
        for _ in 0..<16 where !element.isHittable {
            let start = coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            start.press(forDuration: 0.05, thenDragTo: coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: end)))
        }
    }
}
