import Foundation
import StrideKit

/// What the review screen shows of one pending review, in the order of the
/// design's section 6.4. Built from the server's answer; the server's text is
/// kept as it came, to be shown as plain text, and `completion_notes` is never
/// read.
struct ReviewContent: Hashable, Sendable {
    let taskID: Int
    let identifier: String
    let title: String
    let priority: Priority?
    /// The tasks this review holds up, by identifier.
    let holdsUp: [String]
    let agent: AgentAvatarContent?
    /// How long the agent took.
    let timeSpent: Duration?
    /// The goal, as "G11 Ship the first app build".
    let goal: String?
    /// What the agent says it did: the task's `completion_summary`.
    let summary: String?
    /// The four tiles, in their fixed order, each with its note when it failed.
    let tiles: [ReviewTile]
    /// The `pitfalls` verdict, which "Tests and checks" shows.
    let pitfalls: Verdict?
    /// Every failed verdict with a note, pitfalls included, in the sections'
    /// order, which Request changes offers as chips.
    let findings: [ReviewFinding]
    let checks: ReviewChecks
    /// The security issues the reviewer reported, by severity.
    let securityFindings: ReviewSeverityCounts
    let exploratory: ReviewExploratoryResult
    /// Flagged files first, otherwise in the server's order.
    let files: [ReviewFileRow]
    /// The version of the file list, which a file's index points into.
    let filesVersion: String
    /// The server lets this device approve the change. The app never works
    /// this out from the size: the server decides, and refuses.
    let approvableHere: Bool
    /// How many files and lines the change has, as the server counted them.
    let size: ReviewChangeSize
    /// What the screen was rendered from, which an approval challenge is
    /// bound to, so an edit made since it loaded is never signed unseen.
    let reviewFingerprint: String
    /// When the review was requested, which a decision sends back.
    let reviewRequestedAt: Date?

    /// The tiles that passed.
    var passed: Int { tiles.count(where: { $0.verdict.state == .passed }) }

    /// The tiles two to a row, as the verdicts grid lays them out; an odd
    /// tile out has a row of its own.
    var tileRows: [[ReviewTile]] {
        stride(from: 0, to: tiles.count, by: 2).map { Array(tiles[$0..<min($0 + 2, tiles.count)]) }
    }

    /// The failed tiles' notes, in the tiles' order.
    var failedNotes: [String] { tiles.compactMap(\.note) }

    /// The file screen for a file with a stored diff, which pages through the
    /// review's other files from it.
    func fileTarget(for file: ReviewFileRow) -> ReviewFileTarget? {
        file.index.map { ReviewFileTarget(taskID: taskID, index: $0, filesVersion: filesVersion, files: files) }
    }

    /// Whether any file is flagged, so the list says it shows those first.
    var hasFlaggedFiles: Bool { files.contains(where: \.isFlagged) }

    /// The sections under the header, in the order of design section 6.4:
    /// verdicts before the checks and the files. A section with nothing to
    /// show is left out; "Tests and checks" always shows.
    var sections: [ReviewSectionKind] {
        var sections: [ReviewSectionKind] = []
        if summary != nil { sections.append(.summary) }
        if !tiles.isEmpty { sections.append(.verdicts) }
        sections.append(.checks)
        if !files.isEmpty { sections.append(.files) }
        return sections
    }

    /// "holds up W102, W103", the identifiers as the locale lists them, or
    /// nil when the review holds nothing up.
    func holdsUpLabel(in locale: Locale) -> LocalizedStringResource? {
        guard !holdsUp.isEmpty else { return nil }

        return .reviewHoldsUp(identifiers: holdsUp.formatted(.list(type: .and, width: .narrow).locale(locale)))
    }

    /// The agent, the time it took and the goal, as one line, each as the
    /// server or the locale writes it, or nil when there is none of them.
    func details(in locale: Locale) -> String? {
        let style = Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes], width: .abbreviated)
        let parts = [agent?.name, timeSpent.map { $0.formatted(style.locale(locale)) }, goal].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The word in the pitfalls row's pill, which says the verdict where the
    /// verdict tiles say the section: passed, failed or not assessed.
    func pitfallsText(in locale: Locale) -> String? {
        guard let pitfalls else { return nil }

        let word: LocalizedStringResource = switch pitfalls.state {
        case .passed: .reviewVerdictPassed
        case .failed: .reviewVerdictFailed
        case .notAssessed: .reviewVerdictNotAssessed
        }
        return word.resolved(in: locale)
    }

    /// The project checks' row: all passed, how many were not met, or not
    /// reported.
    func checksResult(in locale: Locale) -> ReviewResult {
        switch checks {
        case .allPassed: ReviewResult(.reviewAllPassed, tone: .stDone, in: locale)
        case .notMet(let count): ReviewResult(.reviewNotMet(count: count), tone: .stBlocked, in: locale)
        case .notReported: ReviewResult(.nowAttemptNotReported, tone: .ink2, in: locale)
        }
    }

    /// The security review's row: no findings, or the count of each
    /// severity, red when any is critical or important.
    func securityResult(in locale: Locale) -> ReviewResult {
        let findings = securityFindings
        guard findings.total > 0 else { return ReviewResult(.reviewNoFindings, tone: .stDone, in: locale) }

        let parts: [LocalizedStringResource] = [
            findings.critical > 0 ? .reviewFindingsCritical(count: findings.critical) : nil,
            findings.important > 0 ? .reviewFindingsImportant(count: findings.important) : nil,
            findings.minor > 0 ? .reviewFindingsMinor(count: findings.minor) : nil,
        ].compactMap { $0 }
        let text = parts.map { $0.resolved(in: locale) }.joined(separator: " · ")
        let tone: ColorToken = findings.critical + findings.important > 0 ? .stBlocked : .stDoing
        return ReviewResult(text: text, tone: tone)
    }

    /// The exploratory testing row: its findings, or the notes on the web.
    func exploratoryResult(in locale: Locale) -> ReviewResult {
        switch exploratory {
        case .seeNotesOnWeb: ReviewResult(.reviewSeeNotesOnWeb, tone: .ink2, in: locale)
        case .findings(0): ReviewResult(.reviewNoFindings, tone: .stDone, in: locale)
        case .findings(let count): ReviewResult(.reviewFindings(count: count), tone: .stDoing, in: locale)
        }
    }
}

extension ReviewContent {
    /// The fixed four the tiles show, as Now's pills do (design section 6.4).
    static let tileSections: [VerdictSection] = [.acceptanceCriteria, .testingStrategy, .patterns, .securityConsiderations]

    init(_ detail: Components.Schemas.ReviewDetail) {
        let task = detail.task
        let verdicts = Self.verdicts(detail.verdicts)

        taskID = task.id
        identifier = task.identifier
        title = task.title
        priority = (task.priority.value1?.rawValue ?? task.priority.value2).flatMap(Priority.init(rawValue:))
        holdsUp = detail.holdsUp.map(\.identifier)
        agent = task.completedByAgent.map { AgentAvatarContent(name: $0) }
        timeSpent = task.timeSpentMinutes.map { .seconds($0 * 60) }
        goal = task.goal.map { "\($0.identifier) \($0.title)" }
        summary = detail.summary
        let criteria = ReviewCriteriaCount(detail.acceptanceCriteria)
        tiles = Self.tileSections.compactMap { section in
            verdicts[section].map {
                ReviewTile(
                    verdict: Verdict(section: section, state: $0.state),
                    note: $0.note,
                    criteria: section == .acceptanceCriteria ? criteria : nil
                )
            }
        }
        pitfalls = verdicts[.pitfalls].map { Verdict(section: .pitfalls, state: $0.state) }
        findings = VerdictSection.allCases.compactMap { section in
            guard let note = verdicts[section]?.note,
                  !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }

            return ReviewFinding(section: section, note: note)
        }
        checks = ReviewChecks(detail.projectChecks)
        securityFindings = ReviewSeverityCounts(
            critical: detail.securityFindings.critical,
            important: detail.securityFindings.important,
            minor: detail.securityFindings.minor
        )
        exploratory = ReviewExploratoryResult(detail.exploratory)
        files = Self.flaggedFirst(detail.files.map(ReviewFileRow.init))
        filesVersion = detail.filesVersion
        approvableHere = detail.approvableHere
        size = ReviewChangeSize(detail.size)
        reviewFingerprint = detail.reviewFingerprint
        reviewRequestedAt = detail.reviewRequestedAt
    }

    /// Flagged files first; the sort is stable, so each group keeps the
    /// server's order.
    static func flaggedFirst(_ files: [ReviewFileRow]) -> [ReviewFileRow] {
        files.filter(\.isFlagged) + files.filter { !$0.isFlagged }
    }

    /// Each section this build knows, with its state and note. A section the
    /// build does not know is left out.
    private static func verdicts(
        _ verdicts: [Components.Schemas.ReviewVerdict]
    ) -> [VerdictSection: (state: VerdictState, note: String?)] {
        var known: [VerdictSection: (state: VerdictState, note: String?)] = [:]
        for verdict in verdicts {
            let name = verdict.section.value1?.rawValue ?? verdict.section.value2
            guard let section = name.flatMap(VerdictSection.init(rawValue:)) else { continue }

            let state = VerdictState(apiValue: verdict.status.flatMap { $0.value1?.rawValue ?? $0.value2 })
            // Only a failed tile shows its note.
            known[section] = (state, state == .failed ? verdict.note : nil)
        }
        return known
    }
}
