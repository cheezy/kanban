import XCTest

/// The tab bar on a phone, or the sidebar on an iPad, after a stub sign-in.
final class ShellUITests: XCTestCase {
    private static let tabs = ["Now", "Review", "Boards", "Agents"]

    @MainActor
    func testEachTabOpensWithVoiceOverLabels() throws {
        let app = signIn()
        try openEachTab(app)

        // The tint and the tokens change with the appearance, so each tab is
        // audited again in dark.
        let appearance = XCUIDevice.shared.appearance
        addTeardownBlock { @MainActor in XCUIDevice.shared.appearance = appearance }
        XCUIDevice.shared.appearance = .dark
        try openEachTab(app)
    }

    @MainActor
    func testHiddenSidebarCanComeBack() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "only an iPad has the sidebar")
        let app = signIn()
        let now = tabControl(app, "Now")
        XCTAssertTrue(now.waitForExistence(timeout: 30))

        let toggle = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "sidebar")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "no button hides the sidebar")
        toggle.tap()
        XCTAssertTrue(wait(for: now, hittable: false), "the sidebar did not hide")

        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "no button brings the sidebar back")
        toggle.tap()
        XCTAssertTrue(wait(for: now, hittable: true), "the sidebar did not come back")
    }

    @MainActor
    func testCornerButtonsOpenNewTaskAndSettings() throws {
        let app = signIn()
        tabControl(app, "Now").tap()

        for (button, title) in [("New task", "New task"), ("Settings", "Settings")] {
            let control = app.buttons[button].firstMatch
            XCTAssertTrue(control.waitForExistence(timeout: 30), "no \(button) button")
            control.tap()

            let heading = app.staticTexts["sheet-title"]
            XCTAssertTrue(heading.waitForExistence(timeout: 10))
            XCTAssertEqual(heading.label, title)
            // On an iPad the form sheet leaves the shell visible, dimmed and out
            // of VoiceOver's reach, around it, and the audit reports that text as
            // "potentially inaccessible text" with no element. Only that is ignored.
            try app.auditAccessibility { issue in
                UIDevice.current.userInterfaceIdiom == .pad
                    && issue.auditType == .elementDetection
                    && issue.element == nil
            }
            app.buttons["Close"].firstMatch.tap()
            XCTAssertTrue(heading.waitForNonExistence(timeout: 10))
        }
    }

    @MainActor
    func testTabsFitTheLargestTextInGerman() throws {
        let app = signIn(locale: "de", textSize: "UICTContentSizeCategoryAccessibilityXXXL")

        for tab in ["Jetzt", "Überprüfung", "Boards", "Agenten"] {
            let control = tabControl(app, tab)
            XCTAssertTrue(control.waitForExistence(timeout: 30), "no \(tab) tab")
            control.tap()
            XCTAssertEqual(app.staticTexts["tab-title"].label, tab)
            // A clipped German row fails here, on every tab's screen. The
            // lazy Now cards are audited too: at the largest size the audit
            // has no larger text to push them off the screen with.
            try app.auditAccessibility(ignoringSidebarContrast)
        }
    }

    /// Opens each tab in turn, checks its title and audits it.
    @MainActor
    private func openEachTab(_ app: XCUIApplication) throws {
        for tab in Self.tabs {
            let control = tabControl(app, tab)
            XCTAssertTrue(control.waitForExistence(timeout: 30), "no \(tab) tab")
            control.tap()

            let title = app.staticTexts["tab-title"]
            XCTAssertTrue(title.waitForExistence(timeout: 10))
            XCTAssertEqual(title.label, tab)
            // The audit's larger text pushes the lazy Now cards off the screen.
            try app.auditAccessibility { $0.isOnLazyNowCard || self.ignoringSidebarContrast($0) }
        }
    }

    /// The audit misreads the contrast of an iPad's sidebar rows
    /// (`isOnSidebarRow`) and of its short mono text, the filter counts and
    /// the cards' identifiers and ages, and scrolls the Now cards under the
    /// tab bar. Only those issues are ignored.
    @MainActor
    private func ignoringSidebarContrast(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        issue.isUnderBarsContrast || issue.isOnNowFilterCount || issue.isOnCardMonoText || issue.isOnSidebarRow
    }

    @MainActor
    private func wait(for element: XCUIElement, hittable: Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == %@", NSNumber(value: hittable)),
            object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: 10) == .completed
    }

    /// A tab bar item on a phone and a sidebar row on an iPad, by its label.
    /// The Now item's label may carry its badge, so it matches the start. A
    /// sidebar row is a button the shell marks `sidebar-tab`.
    @MainActor
    private func tabControl(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        if UIDevice.current.userInterfaceIdiom == .pad {
            let row = NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", "sidebar-tab", label)
            return app.descendants(matching: .any).matching(row).firstMatch
        }
        let predicate = NSPredicate(format: "label BEGINSWITH %@", label)
        return app.tabBars.buttons.matching(predicate).firstMatch
    }

    @MainActor
    private func signIn(locale: String = "en", textSize: String? = nil) -> XCUIApplication {
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
}
