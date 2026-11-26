import XCTest

extension XCUIApplication {
    /// Runs every accessibility audit check, with the contrast check on its own
    /// and first. Some checks, Dynamic Type among them, change the text size
    /// and animate it back, which also scrolls a scrolled screen back to its
    /// top. A contrast check in the same call can then read text that is still
    /// moving and report it as failing, as it does on iOS 26 and 27, so it runs
    /// first, on the screen as the test left it. Use this instead of
    /// `performAccessibilityAudit()`; `issueHandler` works as it does there,
    /// returning true to ignore an issue.
    @MainActor
    func auditAccessibility(_ issueHandler: ((XCUIAccessibilityAuditIssue) throws -> Bool)? = nil) throws {
        try performAccessibilityAudit(for: .contrast, issueHandler)
        try performAccessibilityAudit(for: .all.subtracting(.contrast), issueHandler)
    }
}
