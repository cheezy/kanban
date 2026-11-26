#if DEBUG
import SwiftUI

/// Sample content for the shared views' previews and drawing tests. The
/// titles and names stand in for the server's text.
enum SharedViewSamples: CaseIterable, Sendable {
    case verdicts
    case statuses
    case avatars
    case progress
    case diff
    case offline
    case decision
    case goals

    static let allVerdicts: [Verdict] = VerdictSection.allCases.enumerated().map { index, section in
        Verdict(section: section, state: VerdictState.allCases[index % VerdictState.allCases.count])
    }

    static let agents: [AgentAvatarContent] = [
        AgentAvatarContent(name: "Claude Opus 5.5"),
        AgentAvatarContent(name: "Codex"),
        AgentAvatarContent(name: "Cursor"),
        AgentAvatarContent(name: "Aider"),
        AgentAvatarContent(name: "Goose"),
        AgentAvatarContent(name: "Sam Rivera", isPerson: true),
    ]

    static let progressCounts: [ProgressCounts] = [
        ProgressCounts(total: 9, done: 4, review: 1, doing: 2),
        ProgressCounts(total: 6, done: 6),
        ProgressCounts(total: 5, done: 1, doing: 1, blocked: 1),
        ProgressCounts(total: 0),
    ]

    static let diffLines: [DiffLineContent] = [
        DiffLineContent(kind: .hunk, spans: [HighlightedSpan("@@ -40,3 +40,4 @@")]),
        DiffLineContent(kind: .context, oldNumber: 40, newNumber: 40, spans: [
            HighlightedSpan("def", kind: .keyword), HighlightedSpan(" "),
            HighlightedSpan("done", kind: .function), HighlightedSpan("(t) "),
            HighlightedSpan("do", kind: .keyword),
        ]),
        DiffLineContent(kind: .removed, oldNumber: 41, spans: [
            HighlightedSpan("Repo", kind: .module), HighlightedSpan("."),
            HighlightedSpan("update", kind: .function), HighlightedSpan("(t)"),
        ]),
        // Longer than a phone is wide at the default text size, so it wraps.
        DiffLineContent(kind: .added, newNumber: 41, spans: [
            HighlightedSpan("Repo", kind: .module), HighlightedSpan("."),
            HighlightedSpan("transact", kind: .function), HighlightedSpan("(t, "),
            HighlightedSpan(":done", kind: .atom), HighlightedSpan(", "),
            HighlightedSpan("\"long enough to wrap\"", kind: .string), HighlightedSpan(")"),
        ]),
        DiffLineContent(kind: .added, newNumber: 42, spans: [
            HighlightedSpan("# **no** [link](x)", kind: .comment),
        ]),
    ]

    static let offlineContent = OfflineBannerContent(fetchedAt: Date(timeIntervalSince1970: 1_795_000_000))

    static let decisionContent = DecisionCardContent(
        kind: .review,
        identifier: "W2789",
        title: "Build the shared views: pills, cards, avatars, progress bar and the diff line",
        priority: .critical,
        holdsUp: 3,
        agent: agents[0],
        issue: "after_doing failed: 2 tests",
        verdicts: allVerdicts
    )

    static let goalContents: [GoalCardContent] = [
        GoalCardContent(identifier: "G532", title: "Native mobile apps, phase 1", progress: progressCounts[0], waitingOnYou: 2),
        GoalCardContent(identifier: "G540", title: "Release checklist", progress: progressCounts[2], hookFailed: true),
    ]

    @MainActor @ViewBuilder var view: some View {
        switch self {
        case .verdicts:
            FlowLayout(spacing: 6) {
                ForEach(Self.allVerdicts, id: \.self) { VerdictPill(verdict: $0) }
            }
        case .statuses:
            FlowLayout(spacing: 6) {
                ForEach(TargetStatus.allCases, id: \.self) { StatusPill($0) }
            }
        case .avatars:
            FlowLayout(spacing: 8) {
                ForEach(Self.agents, id: \.self) { AgentAvatar($0) }
                AgentAvatar(Self.agents[0], size: .medium)
                AgentAvatar(Self.agents[5], size: .small)
            }
        case .progress:
            VStack(spacing: 12) {
                ForEach(Self.progressCounts, id: \.self) { ProgressBar(counts: $0) }
            }
        case .diff:
            VStack(spacing: 0) {
                ForEach(Self.diffLines, id: \.self) { DiffLine(line: $0) }
            }
        case .offline:
            OfflineBanner(content: Self.offlineContent)
        case .decision:
            DecisionCard(Self.decisionContent)
        case .goals:
            VStack(spacing: 12) {
                ForEach(Self.goalContents, id: \.self) { GoalCard(content: $0) }
            }
        }
    }

    /// The sample on the screen's background, as a preview shows it.
    @MainActor var preview: some View {
        ScrollView {
            view.padding(16)
        }
        .background(ColorToken.bg.color)
    }
}
#endif
