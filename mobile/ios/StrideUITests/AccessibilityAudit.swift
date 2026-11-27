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

extension XCUIAccessibilityAuditIssue {
    /// A contrast issue on an element scrolled under the tab bar or past the
    /// top edge, where iOS fades the content on purpose: the element reaches
    /// under the tab bar or above the screen, or it is a Now card that cannot
    /// be hit because the bars cover it. The same element passes once it is
    /// scrolled into view.
    @MainActor
    var isUnderBarsContrast: Bool {
        guard auditType == .contrast, let element, element.exists else { return false }

        let app = XCUIApplication()
        let frame = element.frame
        let tabBar = app.tabBars.firstMatch
        if frame.minY < 0 || (tabBar.exists && frame.maxY > tabBar.frame.minY) { return true }
        guard !element.isHittable else { return false }

        return Self.lazyLists.contains { id in
            let list = app.otherElements[id]
            return list.exists && list.frame.intersects(frame)
        }
    }

    /// The lazy lists of cards: the Now cards and the Review queue's rows.
    private static let lazyLists = ["now-cards", "review-rows"]

    /// A contrast issue on a Now filter's count. The count is `ink-3` on
    /// `surface-sunken`, which reaches 5:1, but on an iPad the audit judges the thin
    /// 11-point mono digit from a 7-by-16-point crop and fails it even in
    /// `ink-2`, about 9:1. Only a number inside a `now-filter` segment is
    /// ignored, so the segment's label is still audited.
    @MainActor
    var isOnNowFilterCount: Bool {
        guard auditType == .contrast, let element, element.exists else { return false }
        let label = element.label
        guard !label.isEmpty, label.allSatisfy(\.isNumber) else { return false }

        let frame = element.frame
        return XCUIApplication().buttons.matching(identifier: "now-filter").allElementsBoundByIndex
            .contains { $0.frame.contains(frame) }
    }

    /// A contrast issue on the value in an after_goal attempt row. The value
    /// is `ink` on `surface`, which `SharedViewAccessibilityTests` holds to
    /// 4.5:1 in both themes, but on an iPad the audit judges a lone mono
    /// digit such as the exit code "1" from a tight crop and fails it, as it
    /// does the Now filter counts (W2794). Only an element inside an
    /// `attempt-row` is ignored.
    @MainActor
    var isOnAttemptRowValue: Bool {
        guard auditType == .contrast, let element, element.exists else { return false }

        let frame = element.frame
        return XCUIApplication().descendants(matching: .any).matching(identifier: "attempt-row").allElementsBoundByIndex
            .contains { $0.frame.contains(frame) }
    }

    /// A contrast issue on an iPad sidebar row's title or its Now count. The
    /// titles are `ink` on the sidebar, or `stride-orange-ink` on
    /// `stride-orange-soft` when selected, and the count is `ink` on
    /// `surface`; `SharedViewAccessibilityTests` holds the token pairs to
    /// 4.5:1 in both themes. The audit still fails one title or another from
    /// run to run, on iOS 27 upright and on its side and on iOS 26 in dark,
    /// so only these two elements are ignored, and the rest of the sidebar is
    /// still audited.
    @MainActor
    var isOnSidebarRow: Bool {
        guard auditType == .contrast, let element, element.exists else { return false }

        return ["sidebar-tab-title", "sidebar-count"].contains(element.identifier)
    }

    /// A contrast issue on a decision card's identifier or age: 12-point mono
    /// `ink-3` on `surface`, which `SharedViewAccessibilityTests` holds to
    /// 4.5:1 in both themes. On an iPad the audit fails one short identifier,
    /// such as "D21", from run to run, as it does the filter counts. The
    /// card's other text is still audited.
    @MainActor
    var isOnCardMonoText: Bool {
        guard auditType == .contrast, let element, element.exists else { return false }

        return ["card-identifier", "card-age"].contains(element.identifier)
    }

    /// A Dynamic Type issue on a Now card or a Review queue row after the
    /// first. The audit makes the
    /// text larger, which pushes those cards out of the screen, and the lazy
    /// list then lets go of them, so the audit cannot find their text at the
    /// larger size. The same cards pass in an eager stack, and
    /// `ShellUITests`' largest-text German test audits them without this
    /// filter, since the audit has no larger size to try there. The first
    /// card stays on the screen, so it is still audited in full.
    @MainActor
    var isOnLazyCard: Bool {
        guard auditType == .dynamicType, let element, element.exists else { return false }

        let frame = element.frame
        return Self.lazyLists.contains { id in
            let list = XCUIApplication().otherElements[id]
            let first = list.children(matching: .any).firstMatch
            guard list.exists, first.exists else { return false }

            return list.frame.contains(frame) && frame.minY >= first.frame.maxY
        }
    }
}
