import XCTest

final class UpdateRequiredUITests: XCTestCase {
    @MainActor
    func testShowsUpdateRequiredWithALinkToTheAppStore() throws {
        let app = launch(locale: "en")

        XCTAssertTrue(app.staticTexts["Update required"].waitForExistence(timeout: 30))
        let link = app.links["Open the App Store"]
        XCTAssertTrue(link.isHittable)
        XCTAssertGreaterThanOrEqual(link.frame.height, 44)
        XCTAssertGreaterThanOrEqual(link.frame.width, 44)
        try app.performAccessibilityAudit()

        link.tap()
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 30), "The link opens outside the app")
    }

    @MainActor
    func testFitsTheLargestTextInGerman() throws {
        let app = launch(locale: "de", textSize: "UICTContentSizeCategoryAccessibilityXXXL")

        XCTAssertTrue(app.staticTexts["Update erforderlich"].waitForExistence(timeout: 30))
        let link = app.links["Zum App Store"]
        for _ in 0..<5 where link.isHittable == false {
            app.swipeUp()
        }
        XCTAssertTrue(link.isHittable)
        try app.performAccessibilityAudit()
    }

    @MainActor
    private func launch(locale: String, textSize: String? = nil) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-StrideUpdateRequired", "-AppleLanguages", "(\(locale))"]
        if let textSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", textSize]
        }
        app.launch()

        return app
    }
}
