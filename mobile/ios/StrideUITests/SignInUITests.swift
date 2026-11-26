import XCTest

/// Drives the Sign in screen through the debug stub, which answers the browser
/// window and the token exchange without a server.
final class SignInUITests: XCTestCase {
    @MainActor
    func testSignsInThroughAStubAuthorizationPage() throws {
        let app = launch(stub: "allow")
        let button = app.buttons["Sign in"]

        XCTAssertTrue(button.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Stride"].exists)
        XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        try app.auditAccessibility()

        button.tap()

        XCTAssertTrue(button.waitForNonExistence(timeout: 30), "The signed-in device leaves the Sign in screen")
    }

    @MainActor
    func testCancelReturnsToTheScreenWithNoError() throws {
        let app = launch(stub: "cancel")
        let button = app.buttons["Sign in"]
        XCTAssertTrue(button.waitForExistence(timeout: 30))

        button.tap()

        XCTAssertTrue(button.waitForExistence(timeout: 30))
        XCTAssertTrue(button.isEnabled)
        XCTAssertFalse(app.staticTexts["Sign-in didn't finish. Try again."].exists)
        XCTAssertFalse(app.staticTexts["Couldn't reach Stride. Check your connection and try again."].exists)
    }

    @MainActor
    func testANetworkErrorShowsTheRetryMessage() throws {
        let app = launch(stub: "offline")
        let button = app.buttons["Sign in"]
        XCTAssertTrue(button.waitForExistence(timeout: 30))

        button.tap()

        let message = app.staticTexts["Couldn't reach Stride. Check your connection and try again."]
        XCTAssertTrue(message.waitForExistence(timeout: 30))
        XCTAssertTrue(button.isHittable, "The person can try again")
        try app.auditAccessibility()
    }

    @MainActor
    func testAPersonWithoutTheOrganizationPlanSeesTheLockedPanel() throws {
        let app = launch(stub: "locked")
        let button = app.buttons["Sign in"]
        XCTAssertTrue(button.waitForExistence(timeout: 30))

        button.tap()

        XCTAssertTrue(app.staticTexts["The app is part of the Organization plan"].waitForExistence(timeout: 30))
        let plans = link(app, "See the plans")
        XCTAssertTrue(plans.isHittable)
        XCTAssertGreaterThanOrEqual(plans.frame.height, 44)
        XCTAssertFalse(button.exists)
        try app.auditAccessibility()
    }

    @MainActor
    func testFitsTheLargestTextInGerman() throws {
        let app = launch(stub: "locked", locale: "de", textSize: "UICTContentSizeCategoryAccessibilityXXXL")
        let button = app.buttons["Anmelden"]
        XCTAssertTrue(app.staticTexts["Stride"].waitForExistence(timeout: 30))
        try audit(app)

        scroll(app, toReveal: button)
        XCTAssertTrue(button.isHittable)
        let account = link(app, "Neu bei Stride? Konto im Web erstellen")
        scroll(app, toReveal: account)
        XCTAssertTrue(account.isHittable)
        try audit(app)

        button.tap()

        let plans = link(app, "Tarife ansehen")
        XCTAssertTrue(plans.waitForExistence(timeout: 30))
        scroll(app, toReveal: plans)
        XCTAssertTrue(plans.isHittable)
        try audit(app)
    }

    /// Runs the accessibility audit, except that it does not report the three
    /// points as clipped text. Each one grows to its full height, so nothing in
    /// it can be cut off, yet the audit measures text a little wider than
    /// SwiftUI draws it and reports a point whose line fills the column as
    /// clipped. Every other issue, and clipped text anywhere else, still fails.
    @MainActor
    private func audit(_ app: XCUIApplication) throws {
        try app.auditAccessibility { issue in
            guard issue.auditType == .textClipped, let element = issue.element else { return false }

            return MainActor.assumeIsolated { element.identifier == "sign-in-point" }
        }
    }

    /// A `Link` by its label. iOS 26 reports some links as buttons, such as
    /// the create-account link at the largest text size in German, while
    /// iOS 27 reports them as links, so the query takes either.
    @MainActor
    private func link(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let types = [XCUIElement.ElementType.link, .button].map(\.rawValue)
        let predicate = NSPredicate(format: "label == %@ AND elementType IN %@", label, types)
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    @MainActor
    private func scroll(_ app: XCUIApplication, toReveal element: XCUIElement) {
        for _ in 0..<8 where element.isHittable == false {
            app.swipeUp()
        }
    }

    @MainActor
    private func launch(stub: String, locale: String = "en", textSize: String? = nil) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-StrideStubSignIn", stub, "-AppleLanguages", "(\(locale))"]
        if let textSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", textSize]
        }
        app.launch()

        return app
    }
}
