import CoreGraphics
import Foundation
import Testing

@testable import Stride

/// The shared views' content: what they work out from what the server sends.
struct SharedViewContentTests {
    @Test("progress counts are clamped to the total and split into segments")
    func progressSegments() {
        let counts = ProgressCounts(total: 9, done: 4, review: 1, doing: 2)
        #expect(counts.toDo == 2)
        #expect(counts.segments.map(\.kind) == [.done, .review, .doing, .toDo])
        #expect(counts.segments.map(\.count) == [4, 1, 2, 2])

        let over = ProgressCounts(total: 3, done: 5, review: 2, doing: -1, blocked: 4)
        #expect(over.done == 3)
        #expect(over.review == 0)
        #expect(over.doing == 0)
        #expect(over.blocked == 0)
        #expect(over.toDo == 0)

        #expect(ProgressCounts(total: -2).total == 0)
        #expect(ProgressCounts(total: 0).segments.isEmpty)
    }

    @Test("segment widths share the bar by count and keep a small one visible")
    func segmentWidths() {
        let even = ProgressSegment.widths(
            of: [ProgressSegment(kind: .done, count: 2), ProgressSegment(kind: .toDo, count: 1)], in: 303, gap: 3)
        #expect(even == [200, 100])

        // One task in 300 would be a single point wide; it gets the gap's
        // width, taken from the other segment so the bar keeps its width.
        let segments = [ProgressSegment(kind: .done, count: 299), ProgressSegment(kind: .toDo, count: 1)]
        #expect(ProgressSegment.widths(of: segments, in: 303, gap: 3) == [297, 3])

        let counts = [196, 1, 1, 1, 1]
        let fewSmall = counts.map { ProgressSegment(kind: .done, count: $0) }
        let widths = ProgressSegment.widths(of: fewSmall, in: 312, gap: 3)
        let filled: CGFloat = widths.reduce(0, +)
        #expect(widths == [288, 3, 3, 3, 3])
        #expect(filled == 300, "the segments and their four gaps fill the bar")
        #expect(ProgressSegment.widths(of: [], in: 100, gap: 3).isEmpty)
    }

    @Test("an avatar shows two initials and the family's colours")
    func avatarInitials() {
        let english = Locale(identifier: "en")

        #expect(AgentAvatarContent(name: "Claude Opus 5.5").initials(in: english) == "CL")
        #expect(AgentAvatarContent(name: "Sam Rivera", isPerson: true).initials(in: english) == "SR")
        #expect(AgentAvatarContent(name: "Ana", isPerson: true).initials(in: english) == "AN")
        #expect(AgentAvatarContent(name: "  ").initials(in: english) == nil)
        #expect(AgentAvatarContent(name: "5.5 codex").initials(in: english) == "CO")

        #expect(AgentFamily(name: "Claude Opus 5.5", isPerson: false) == .claude)
        #expect(AgentFamily(name: "OpenAI Codex", isPerson: false) == .codex)
        #expect(AgentFamily(name: "Cursor Agent", isPerson: false) == .cursor)
        #expect(AgentFamily(name: "aider", isPerson: false) == .aider)
        #expect(AgentFamily(name: "Goose", isPerson: false) == .otherAgent)
        #expect(AgentFamily(name: "Claude", isPerson: true) == .person)
        #expect(AvatarSize.regular.side == 36)
        #expect(AvatarSize.small.side == 22)
    }

    @Test("API values map to their cases")
    func targetStatuses() {
        #expect(TargetStatus.allCases.map(\.rawValue) == ["on_track", "at_risk", "missed", "complete"])
        #expect(Set(TargetStatus.allCases.map(\.tone)).count == TargetStatus.allCases.count)
        #expect(TargetStatus.allCases.allSatisfy { !$0.label.resolved(in: Locale(identifier: "en")).isEmpty })
    }

    @Test("a decision card's kind and counts come from the API's values")
    func decisionContent() {
        #expect(DecisionKind(rawValue: "claim_expired") == .claimExpired)
        #expect(DecisionKind.allCases.allSatisfy { !$0.label.resolved(in: Locale(identifier: "de")).isEmpty })
        #expect(DecisionCardContent(kind: .review, identifier: "W1", title: "t", holdsUp: -3).holdsUp == 0)
        #expect(GoalCardContent(identifier: "G1", title: "t", progress: ProgressCounts(total: 1), waitingOnYou: -1).waitingOnYou == 0)
        #expect(Priority(rawValue: "critical")?.color == .priCritical)
    }

    @Test("the offline banner says when the data was fetched, in the reader's time zone")
    func offlineMessage() {
        let content = OfflineBannerContent(fetchedAt: Date(timeIntervalSince1970: 0))
        let utc = TimeZone(identifier: "UTC")!
        let english = content.message(in: Locale(identifier: "en_US"), timeZone: utc)
        let german = content.message(in: Locale(identifier: "de_DE"), timeZone: utc)

        #expect(english.hasPrefix("Offline · showing what you had at 12:00"))
        #expect(english.contains("AM"))
        #expect(german.hasPrefix("Offline · Stand von "))
        #expect(german.hasSuffix("0:00"))
        #expect(german.contains("AM") == false)
    }

    @Test("a decision's age is its largest unit, and nothing without a start")
    func decisionAge() {
        let since = Date(timeIntervalSince1970: 1_795_000_000)
        let content = DecisionCardContent(kind: .review, identifier: "W1", title: "T", since: since)
        let english = Locale(identifier: "en")

        #expect(content.age(at: since.addingTimeInterval(120), in: english) == "2m")
        #expect(content.age(at: since.addingTimeInterval(3 * 3600 + 60), in: english) == "3h")
        #expect(content.age(at: since.addingTimeInterval(2 * 86400), in: english) == "2d")
        #expect(content.age(at: since.addingTimeInterval(120), in: english, width: .wide) == "2 minutes")
        // A clock behind the server's says no time has passed.
        #expect(content.age(at: since.addingTimeInterval(-60), in: english) == "0m")
        #expect(DecisionCardContent(kind: .review, identifier: "W1", title: "T").age(at: since, in: english) == nil)
    }

    @Test("a file's line counts carry their sign and the locale's grouping", arguments: [
        ("en", 3, "+3", "\u{2212}3"),
        ("en", 1234, "+1,234", "\u{2212}1,234"),
        ("de", 1234, "+1.234", "\u{2212}1.234"),
    ])
    func lineCounts(locale: String, count: Int, added: String, removed: String) {
        let locale = Locale(identifier: locale)

        #expect(LineCountText.added(count, in: locale) == added)
        #expect(LineCountText.removed(count, in: locale) == removed)
    }
}
