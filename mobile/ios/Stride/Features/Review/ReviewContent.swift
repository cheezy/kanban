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
    let checks: ReviewChecks
    /// The security issues the reviewer reported, by severity.
    let securityFindings: ReviewSeverityCounts
    let exploratory: ReviewExploratoryResult
    /// Flagged files first, otherwise in the server's order.
    let files: [ReviewFileRow]
    /// The server lets this device approve the change.
    let approvableHere: Bool
    /// The change is too large for this device to approve.
    let tooLargeHere: Bool

    /// The tiles that passed.
    var passed: Int { tiles.count(where: { $0.verdict.state == .passed }) }

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

/// A section of the review screen under its header.
enum ReviewSectionKind: Hashable, Sendable {
    case summary
    case verdicts
    case checks
    case files
}

/// One result in "Tests and checks": its words and its colour.
struct ReviewResult: Hashable, Sendable {
    let text: String
    let tone: ColorToken

    init(text: String, tone: ColorToken) {
        self.text = text
        self.tone = tone
    }

    init(_ resource: LocalizedStringResource, tone: ColorToken, in locale: Locale) {
        self.init(text: resource.resolved(in: locale), tone: tone)
    }
}

/// How many security issues the reviewer reported at each severity.
struct ReviewSeverityCounts: Hashable, Sendable {
    let critical: Int
    let important: Int
    let minor: Int

    var total: Int { critical + important + minor }
}

/// How many acceptance criteria the reviewer marked met, of how many.
struct ReviewCriteriaCount: Hashable, Sendable {
    let met: Int
    let count: Int

    init(met: Int, count: Int) {
        self.met = met
        self.count = count
    }

    /// The reviewer's results, or nil when it gave no status for any of them.
    init?(_ criteria: [Components.Schemas.ReviewAcceptanceCriterion]) {
        guard criteria.contains(where: { $0.status != nil }) else { return nil }

        met = criteria.count(where: { $0.status == "met" })
        count = criteria.count
    }

    /// "4/4", as the tile shows it.
    var text: LocalizedStringResource { .reviewCriteriaCount(met: String(met), count: count) }

    /// "4 of 4 criteria met", for VoiceOver.
    func reading(in locale: Locale) -> String {
        LocalizedStringResource.reviewCriteriaMet(met: String(met), count: count).resolved(in: locale)
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
        checks = ReviewChecks(detail.projectChecks)
        securityFindings = ReviewSeverityCounts(
            critical: detail.securityFindings.critical,
            important: detail.securityFindings.important,
            minor: detail.securityFindings.minor
        )
        exploratory = ReviewExploratoryResult(detail.exploratory)
        files = Self.flaggedFirst(detail.files.map(ReviewFileRow.init))
        approvableHere = detail.approvableHere
        tooLargeHere = !detail.approvableHere
            && (detail.approvableHereReason?.value1 == .tooLargeForPhone || detail.size.largeChange)
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

/// One verdict tile.
struct ReviewTile: Hashable, Sendable {
    let verdict: Verdict
    /// The reviewer's note, for a failed tile.
    let note: String?
    /// How many criteria were met, on the acceptance tile.
    let criteria: ReviewCriteriaCount?

    /// The verdict in words, with the criteria met on the acceptance tile,
    /// for VoiceOver.
    func reading(in locale: Locale) -> String {
        [verdict.reading(in: locale), criteria?.reading(in: locale)].compactMap { $0 }.joined(separator: ", ")
    }
}

/// The project checks' result, for "Tests and checks".
enum ReviewChecks: Hashable, Sendable {
    case allPassed
    case notMet(Int)
    /// The reviewer reported no checks.
    case notReported

    init(_ checks: Components.Schemas.ReviewProjectChecks) {
        if checks.notMet > 0 {
            self = .notMet(checks.notMet)
        } else if checks.met > 0 {
            self = .allPassed
        } else {
            self = .notReported
        }
    }
}

/// What the exploratory testing row says.
enum ReviewExploratoryResult: Hashable, Sendable {
    case findings(Int)
    /// No structured block was stored, so the notes are on the web.
    case seeNotesOnWeb

    init(_ exploratory: Components.Schemas.ReviewExploratory) {
        self = exploratory.count.map(Self.findings) ?? .seeNotesOnWeb
    }
}

/// One changed file in the list.
struct ReviewFileRow: Hashable, Sendable, Identifiable {
    /// The file's position in the stored diffs, or nil when no diff is stored.
    let index: Int?
    let path: String
    let additions: Int?
    let deletions: Int?
    let isFlagged: Bool

    var id: String { path }

    /// A file with a stored diff opens it.
    var opens: Bool { index != nil }

    /// What VoiceOver reads for the row: flagged or not, the file's name in
    /// its folder, and its added and removed lines in words, so it neither
    /// reads a bare path nor "plus 120".
    func reading(in locale: Locale) -> String {
        let slash = path.lastIndex(of: "/")
        let place: LocalizedStringResource? = slash.map {
            .reviewFileIn(name: String(path[path.index(after: $0)...]), folder: String(path[..<$0]))
        }
        let parts: [String?] = [
            isFlagged ? LocalizedStringResource.reviewFlagged.resolved(in: locale) : nil,
            place?.resolved(in: locale) ?? path,
            additions.map { LocalizedStringResource.reviewLinesAdded(count: $0).resolved(in: locale) },
            deletions.map { LocalizedStringResource.reviewLinesRemoved(count: $0).resolved(in: locale) },
        ]
        return parts.compactMap { $0 }.joined(separator: ", ")
    }

    init(_ file: Components.Schemas.ReviewFile) {
        index = file.index
        path = file.path
        additions = file.additions
        deletions = file.deletions
        isFlagged = file.flagged
    }
}

/// A review that changed since the screen loaded it, from an HTTP 409.
enum ReviewConflictState: Hashable, Sendable {
    /// Someone decided it first: who, what they decided, and when.
    case alreadyDecided(by: String?, decision: ReviewDecision, at: Date?)
    /// The agent sent it for review again.
    case resubmitted

    /// The conflict the screen shows for the server's answer. An `edited`
    /// conflict, which only the approval challenge sends, reads as
    /// Resubmitted, since a reload settles it the same way.
    init(_ conflict: Components.Schemas.ReviewConflict) {
        let error = conflict.error.value1?.rawValue ?? conflict.error.value2
        switch error {
        case "already_decided":
            let review = conflict.review
            let status = review.reviewStatus.flatMap { $0.value1?.rawValue ?? $0.value2 }
            self = .alreadyDecided(
                by: review.reviewedBy,
                decision: ReviewDecision(apiValue: status),
                at: review.reviewedAt
            )
        default:
            self = .resubmitted
        }
    }
}

/// What the person who decided first decided.
enum ReviewDecision: Hashable, Sendable {
    case approved
    case changesRequested
    case other

    init(apiValue: String?) {
        switch apiValue {
        case "approved": self = .approved
        case "changes_requested": self = .changesRequested
        default: self = .other
        }
    }
}

/// What a conflict says, kept apart from the view so tests read it.
enum ReviewConflictCopy {
    static func message(for conflict: ReviewConflictState) -> LocalizedStringResource {
        switch conflict {
        case .resubmitted: .reviewResubmittedHint
        case .alreadyDecided(by: nil, _, _): .reviewDecidedSomeone
        case .alreadyDecided(by: let name?, decision: .approved, _): .reviewDecidedApproved(name: name)
        case .alreadyDecided(by: let name?, decision: .changesRequested, _): .reviewDecidedChanges(name: name)
        case .alreadyDecided(by: let name?, decision: .other, _): .reviewDecidedOther(name: name)
        }
    }

    /// When it was decided, such as "2 minutes ago", as the locale says it.
    static func when(_ date: Date, relativeTo now: Date, in locale: Locale) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
