import XCTest

final class LaunchUITests: XCTestCase {
    @MainActor
    func testLaunchesToAnAccessibleScreen() throws {
        continueAfterFailure = false
        let app = XCUIApplication()

        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        try app.auditAccessibility()
    }
}
