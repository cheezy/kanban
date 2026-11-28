import XCTest

extension XCUIApplication {
    /// Runs every accessibility audit check, with the contrast check on its own
    /// and first. Some checks, Dynamic Type among them, change the text size
    /// and animate it back, which also scrolls a scrolled screen back to its
    /// top. A contrast check in the same call can then read text that is still
    /// moving and report it as failing, as it does on iOS 26 and 27, so it runs
    /// first, on the screen as the test left it. Use this instead of
    /// `performAccessibilityAudit()`; `issueHandler` works as it does there,
    /// returning true to ignore an issue. `skipping` leaves checks out, such
    /// as `.dynamicType` when a long screen at the largest text is audited a
    /// second time, where it resizes every element again and the audit can
    /// run out of time (W2796).
    @MainActor
    func auditAccessibility(
        skipping skipped: XCUIAccessibilityAuditType = [],
        _ issueHandler: ((XCUIAccessibilityAuditIssue) throws -> Bool)? = nil
    ) throws {
        try audit(.contrast, issueHandler)
        try audit(.all.subtracting(.contrast).subtracting(skipped), issueHandler)
    }

    /// One audit, run a second time only when the first ran out of time
    /// (code -56), which reports nothing about the screen. A long screen at
    /// the largest text sometimes overran on one call or another (W2796); an
    /// issue the audit finds still fails at once. Each issue not ignored is
    /// also printed with its element, since the failure itself names only
    /// the kind of issue, so a failing run says what failed without a
    /// second run to find it (W2800).
    @MainActor
    private func audit(
        _ types: XCUIAccessibilityAuditType,
        _ issueHandler: ((XCUIAccessibilityAuditIssue) throws -> Bool)?
    ) throws {
        let reporting: (XCUIAccessibilityAuditIssue) throws -> Bool = { issue in
            let ignored = try issueHandler?(issue) ?? false
            if !ignored { print(Self.describe(issue)) }
            return ignored
        }
        do {
            try performAccessibilityAudit(for: types, reporting)
        } catch let error as NSError where error.domain == "com.apple.xcode.xctest.accessibilityAudit" && error.code == -56 {
            try performAccessibilityAudit(for: types, reporting)
        }
    }

    /// One line naming an issue's element: its identifier, type, frame and
    /// label. The label is the app's own text or fixture text, never a token.
    @MainActor
    private static func describe(_ issue: XCUIAccessibilityAuditIssue) -> String {
        guard let element = issue.element, element.exists else {
            return "AUDIT-ISSUE: \(issue.compactDescription) | no element"
        }
        let identifier = element.identifier.isEmpty ? "-" : element.identifier
        return "AUDIT-ISSUE: \(issue.compactDescription) | id=\(identifier) | type=\(element.elementType.rawValue) "
            + "| frame=\(element.frame) | label=\(element.label)"
    }
}

extension XCUIAccessibilityAuditIssue {
    /// A contrast issue on an element scrolled under the tab bar, under the
    /// navigation bar, under a pinned bottom bar or past the top edge, where iOS fades the content on
    /// purpose: the element reaches under either bar or above the screen, or
    /// it is a Now card that cannot be hit because the bars cover it. The same
    /// element passes once it is scrolled into view. A review heading faded
    /// under the navigation bar failed this way at the largest text (W2796).
    @MainActor
    var isUnderBarsContrast: Bool {
        guard auditType == .contrast, let element, element.exists else { return false }

        let app = XCUIApplication()
        let frame = element.frame
        let tabBar = app.tabBars.firstMatch
        if frame.minY < 0 || (tabBar.exists && frame.maxY > tabBar.frame.minY) { return true }
        // A review's files heading half under the review's pinned buttons
        // failed in dark (W2797). The bar's own buttons are still audited:
        // they are told apart by being inside the bar, not by their place,
        // since a heading half under it has its middle inside the bar too.
        let underPinnedBar = Self.pinnedBars.contains { id in
            let bar = app.descendants(matching: .any)[id].firstMatch
            // A toast's shadow reaches above it over the content, which the
            // audit read as faded: "1 minor" just above the Approved toast
            // failed on the iOS 27.2 iPhone 18 Pro, on main too (W2801).
            let top = bar.exists ? bar.frame.minY - (Self.shadowedBars.contains(id) ? Self.toastShadowReach : 0) : 0
            // Behind it, not below it: the review's buttons under a notice
            // pinned above them are still audited.
            guard bar.exists, frame.maxY > top, frame.minY < bar.frame.maxY else { return false }

            let sameLabel = NSPredicate(format: "label == %@", element.label)
            return !bar.descendants(matching: .any).matching(sameLabel).firstMatch.exists
        }
        if underPinnedBar { return true }
        // Content reaching under a navigation bar, or scrolled wholly under
        // it, as a review's files heading was on an iPad at the largest text
        // (W2796); the bar's own title and buttons are its descendants and
        // are still audited.
        let underNavigationBar = app.navigationBars.allElementsBoundByIndex.contains { bar in
            guard bar.frame.intersects(frame) else { return false }
            guard bar.frame.contains(frame) else { return true }

            let sameLabel = NSPredicate(format: "label == %@", element.label)
            return !bar.descendants(matching: .any).matching(sameLabel).firstMatch.exists
        }
        if underNavigationBar { return true }
        guard !element.isHittable else { return false }

        return Self.lazyLists.contains { id in
            let list = app.otherElements[id]
            return list.exists && list.frame.intersects(frame)
        }
    }

    /// A contrast issue on a sheet's content scrolled past the sheet's edge.
    /// On an iPad a form sheet is shorter than the screen, and at the largest
    /// text the Request changes sheet's chip scrolled below it, where the
    /// audit judged it against the dimmed screen behind the sheet (W2800).
    /// Only on an iPad, and only an element of the sheet's own scroll view
    /// that the sheet does not wholly show is ignored; the test scrolls the
    /// sheet on to its last line and audits each part there, so no row past
    /// the edge goes unaudited.
    @MainActor
    var isPastSheetEdge: Bool {
        guard UIDevice.current.userInterfaceIdiom == .pad,
              auditType == .contrast, let element, element.exists else { return false }

        let sheet = XCUIApplication().scrollViews.containing(.staticText, identifier: "sheet-title").firstMatch
        guard sheet.exists, !sheet.frame.contains(element.frame) else { return false }

        let sameLabel = NSPredicate(format: "label == %@", element.label)
        return sheet.descendants(matching: .any).matching(sameLabel).firstMatch.exists
    }

    /// On an iPad a form sheet leaves the screen behind it dimmed and out of
    /// VoiceOver's reach, and the audit reports that text as "potentially
    /// inaccessible text" with no element (W2790). Only that issue is
    /// ignored, and only on an iPad.
    @MainActor
    var isBehindFormSheet: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && auditType == .elementDetection && element == nil
    }

    /// The bars of buttons pinned over the bottom of a scrolled screen, and
    /// the review's problem notice, Approved toast or Changes requested toast
    /// pinned above its bar, which on a phone covers the review text scrolled
    /// behind it (W2799, W2800).
    private static let pinnedBars = ["review-bottom-bar", "review-problem-notice", "review-approved-toast", "review-changes-toast", "diff-bottom-bar"]

    /// The pinned toasts drawn with a shadow, and how far above them it
    /// reaches: `DecisionToast`'s shadow radius, 12 points.
    private static let shadowedBars: Set<String> = ["review-approved-toast", "review-changes-toast"]
    private static let toastShadowReach: CGFloat = 12

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

    /// A contrast issue on the file screen's "flagged" pill: semibold
    /// footnote `st-blocked` on `st-blocked-soft`, which
    /// `SharedViewAccessibilityTests` holds to 4.5:1 in both themes (about
    /// 7:1 in dark). The audit failed it in dark on the iOS 27.2 iPad and
    /// on both iOS 26.4 simulators while the iOS 27.2 iPhone passed it
    /// (W2797). Only the pill is ignored; the rest of the header is still
    /// audited.
    @MainActor
    var isOnFlaggedPill: Bool {
        guard auditType == .contrast, let element, element.exists else { return false }

        return element.identifier == "diff-flagged"
    }

    /// A contrast issue on a line of a diff on an iPad. Each line is one
    /// element, and the audit judged a context line from a crop of its
    /// lone mono line number, "1" in `ink-3` on `surface`, on the iOS 27.2
    /// and 26.4 iPads in light and dark, as it does the Now filter counts
    /// (W2797). `SharedViewAccessibilityTests` holds every line number,
    /// text and highlight ink to 4.5:1 on each line's background in both
    /// themes, and the iPhones still audit the lines. Only on an iPad and
    /// only on a `diff-line`; the notes between the lines are still audited.
    @MainActor
    var isOnDiffLineOnIPad: Bool {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return false }
        guard auditType == .contrast, let element, element.exists else { return false }
        if element.identifier == "diff-line" { return true }

        let frame = element.frame
        return XCUIApplication().descendants(matching: .any).matching(identifier: "diff-line")
            .allElementsBoundByIndex.contains { $0.frame.contains(frame) }
    }

    /// A contrast issue on the review screen's acceptance tile, whose
    /// criteria count, such as "2/2", is 12-point mono `st-done` on
    /// `st-done-soft`. `SharedViewAccessibilityTests` holds every verdict's
    /// ink on its fill to 4.5:1 in both themes, but on an iPad the audit
    /// judges the short count from a tight crop and fails it, as it does the
    /// Now filter counts (W2796). The other verdict tiles are still audited.
    @MainActor
    var isOnCriteriaTile: Bool {
        guard auditType == .contrast, let element, element.exists else { return false }

        let frame = element.frame
        return XCUIApplication().descendants(matching: .any).matching(identifier: "review-criteria-tile")
            .allElementsBoundByIndex.contains { $0.frame.contains(frame) }
    }

    /// A clipped-text or Dynamic Type issue on text in a review section that
    /// reaches under the review screen's bottom bar, which covers the end of
    /// the scrolled content on purpose, as the tab bar does. The audit grows
    /// the text, which pushes the rest of that section under the bar, and
    /// reports the text's frame at the normal size, so the section's frame is
    /// what is checked: "Tests and checks" sat above the bar and was still
    /// reported "may be clipped at larger Dynamic Type sizes". The last
    /// section above the bar counts too when the next one starts under it.
    /// Sections higher up, and the bar's own buttons, are still audited,
    /// and `ReviewUITests`' largest-text test audits the whole screen
    /// without this filter (W2796).
    @MainActor
    var isUnderReviewBottomBar: Bool {
        guard auditType == .textClipped || auditType == .dynamicType, let element, element.exists else { return false }

        let app = XCUIApplication()
        let bar = app.descendants(matching: .any)["review-bottom-bar"].firstMatch
        guard bar.exists else { return false }

        let frame = element.frame
        // The bar's own buttons sit inside it, so they are audited.
        if bar.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) { return false }
        let barTop = bar.frame.minY
        if frame.maxY > barTop { return true }
        return Self.reviewSections.indices.contains { index in
            let section = app.descendants(matching: .any)[Self.reviewSections[index]].firstMatch
            guard section.exists, section.frame.contains(frame) else { return false }
            if section.frame.maxY > barTop { return true }

            // The last section above the bar, which the audit's larger text
            // pushes under it: the next section already starts under the
            // bar. "Tests and checks" ended just above the bar on the iOS
            // 27.2 iPhone 18 Pro and failed there, on main too (W2801).
            guard index + 1 < Self.reviewSections.count else { return false }
            let next = app.descendants(matching: .any)[Self.reviewSections[index + 1]].firstMatch
            return next.exists && next.frame.minY >= barTop
        }
    }

    /// A contrast issue that the iOS 26 audit reports on the review screen's
    /// bar buttons, its header's agent and details line, its "Flagged
    /// first" line or a section's heading, or on the file screen's bar
    /// buttons. Their pairs (`ink` on `surface` and back for the
    /// buttons, each agent family's ink on its fill, `ink-2` on `surface`
    /// and on `bg`, `ink-3` on `surface` for a heading)
    /// are held to 4.5:1 in both themes by `SharedViewAccessibilityTests`,
    /// and iOS 27 passes them. iOS 26.4 failed them on every run, on a fresh
    /// launch too, once judging the Approve button from a crop of its lower
    /// edge (W2796). It failed the file screen's "Back to verdicts" on the
    /// iPhone and "What the agent says it did" just above the tab bar at the
    /// largest text in dark, on every run (W2797). Only on iOS 26 and only
    /// inside these elements; the rest of the screen is still audited.
    @MainActor
    var isOnReviewContrastMisjudgedOnIOS26: Bool {
        guard #available(iOS 26, *) else { return false }
        guard #unavailable(iOS 27) else { return false }
        guard auditType == .contrast, let element, element.exists else { return false }
        if element.identifier == "review-section-heading" { return true }

        let frame = element.frame
        return ["review-bottom-bar", "diff-bottom-bar", "review-details", "review-flagged-first"].contains { id in
            let container = XCUIApplication().descendants(matching: .any)[id].firstMatch
            return container.exists && container.frame.contains(frame)
        }
    }

    /// A clipped-text issue that the iOS 17 and 18 audit reports on a Now
    /// filter's label, which is in Geist, a variable font, at the medium
    /// weight. At the largest text in German it failed "Prüfungen" though the
    /// whole word showed with room to spare, and it still failed it with the
    /// segments' label and count stacked, with no line limit and no scale
    /// factor, and with the weight passed in the font; at the regular weight
    /// it passed, and iOS 26 and 27 pass it at the medium weight (W2797).
    /// Only before iOS 26 and only on that label; its count and the rest of
    /// the screen are still audited.
    @MainActor
    var isNowFilterLabelClippedBeforeIOS26: Bool {
        guard #unavailable(iOS 26) else { return false }
        guard auditType == .textClipped, let element, element.exists else { return false }

        return element.identifier == "now-filter-label"
    }

    /// A description issue on the file screen's title, which is the file's
    /// name as the server sends it, such as "greeting.ex". The audit calls a
    /// name with an extension "not human-readable" at the largest text, but
    /// it is the name the reviewer looks for, and the header's path under it
    /// is read as the name in its folder (W2797). Only the navigation bar's
    /// title is ignored, and only when `diff-path`'s reading names it.
    @MainActor
    var isFileNameTitle: Bool {
        guard auditType == .sufficientElementDescription, let element, element.exists else { return false }

        let app = XCUIApplication()
        let path = app.staticTexts["diff-path"].firstMatch
        guard path.exists, !element.label.isEmpty, path.label.contains(element.label) else { return false }

        return app.navigationBars.allElementsBoundByIndex.contains { $0.frame.contains(element.frame) }
    }

    /// The review screen's section cards.
    private static let reviewSections = ["review-summary", "review-verdicts", "review-checks", "review-files"]

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
