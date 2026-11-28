import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Stride

/// What the shared views say to VoiceOver, and the colours they draw with.
struct SharedViewAccessibilityTests {
    private static let english = Locale(identifier: "en")
    private static let german = Locale(identifier: "de")

    @Test("pills and progress bars read their state in words")
    func pillsAndBarsRead() {
        #expect(Verdict(section: .patterns, state: .failed).reading(in: Self.english) == "Patterns failed")
        #expect(Verdict(section: .acceptanceCriteria, state: .passed).reading(in: Self.english) == "Acceptance passed")
        #expect(Verdict(section: .securityConsiderations, state: .notAssessed).reading(in: Self.english) == "Security not assessed")
        #expect(Verdict(section: .patterns, state: .failed).reading(in: Self.german) == "Muster nicht bestanden")

        #expect(TargetStatus.atRisk.label.resolved(in: Self.english) == "At-risk")
        #expect(TargetStatus.onTrack.label.resolved(in: Self.german) == "Im Plan")
        #expect(Priority.critical.label.resolved(in: Self.english) == "Critical priority")
        #expect(Priority.low.label.resolved(in: Self.german) == "Niedrige Priorität")

        let partial = ProgressCounts(total: 9, done: 4, review: 1, doing: 2)
        #expect(partial.reading(in: Self.english) == "4 of 9 done, 1 in review, 2 in progress")
        let german = partial.reading(in: Self.german)
        for part in ["4 von 9 erledigt", "1 in Prüfung", "2 in Arbeit"] {
            #expect(german.contains(part), "\(german) lacks \(part)")
        }

        #expect(ProgressCounts(total: 6, done: 6).reading(in: Self.english) == "6 of 6 done")
        #expect(ProgressCounts(total: 3, blocked: 1).reading(in: Self.english).contains("1 blocked"))
        #expect(ProgressCounts(total: 0).reading(in: Self.english) == "No tasks yet")
        #expect(ProgressCounts(total: 0).reading(in: Self.german) == "Noch keine Aufgaben")
    }

    @Test("every verdict state from the API has its own words and colours")
    func verdictStates() {
        #expect(VerdictState(apiValue: "passed") == .passed)
        #expect(VerdictState(apiValue: "failed") == .failed)
        #expect(VerdictState(apiValue: "not_assessed") == .notAssessed)
        #expect(VerdictState(apiValue: nil) == .notAssessed)
        #expect(VerdictState(apiValue: "maybe") == .notAssessed)
        #expect(Set(VerdictState.allCases.map(\.fill)).count == VerdictState.allCases.count)
        #expect(Set(VerdictState.allCases.map(\.symbol)).count == VerdictState.allCases.count)
        #expect(VerdictSection(rawValue: "security_considerations") == .securityConsiderations)
    }

    @Test("a diff line reads added or removed")
    func diffLineReads() {
        let added = DiffLineContent(kind: .added, newNumber: 42, spans: [HighlightedSpan("x")])
        let removed = DiffLineContent(kind: .removed, oldNumber: 41, newNumber: 99, spans: [HighlightedSpan("y")])
        let context = DiffLineContent(kind: .context, oldNumber: 1_200, newNumber: 1_203, spans: [HighlightedSpan("z")])
        let hunk = DiffLineContent(kind: .hunk, spans: [HighlightedSpan("@@")])

        #expect(added.reading(in: Self.english) == "Added, line 42")
        #expect(removed.reading(in: Self.english) == "Removed, line 41")
        #expect(context.reading(in: Self.english) == "Line 1203")
        #expect(added.reading(in: Self.german) == "Hinzugefügt, Zeile 42")
        #expect(hunk.reading(in: Self.english) == nil)

        #expect(DiffLineKind(apiValue: "add") == .added)
        #expect(DiffLineKind(apiValue: "del") == .removed)
        #expect(DiffLineKind(apiValue: "hunk") == .hunk)
        #expect(DiffLineKind(apiValue: "weird") == .context)
        #expect(DiffLineKind.added.marker != DiffLineKind.removed.marker)
    }

    @Test("a line's gutter holds its number and its marker in one run")
    func gutter() {
        #expect(DiffLineContent(kind: .added, newNumber: 42, spans: []).gutter(in: Self.english) == "42 +")
        #expect(DiffLineContent(kind: .removed, oldNumber: 1203, spans: []).gutter(in: Self.german) == "1203 −")
        #expect(DiffLineContent(kind: .context, oldNumber: 7, newNumber: 7, spans: []).gutter(in: Self.english) == "7  ")
        #expect(DiffLineContent(kind: .hunk, spans: []).gutter(in: Self.english).isEmpty)
    }

    @Test("a highlighted span maps to its token colour")
    func highlightColours() {
        #expect(HighlightClass(apiValue: "keyword").ink == .stReview)
        #expect(HighlightClass(apiValue: "function").ink == .stReady)
        #expect(HighlightClass(apiValue: "string").ink == .stDone)
        #expect(HighlightClass(apiValue: "atom").ink == .strideOrangeInk)
        #expect(HighlightClass(apiValue: "<script>").ink == nil)
        #expect(HighlightClass(apiValue: nil) == .plain)

        let line = DiffLineContent(kind: .added, newNumber: 1, spans: [
            HighlightedSpan("def", kind: .keyword), HighlightedSpan(" x", kind: .plain),
        ])
        let runs = line.attributedText().runs.map(\.foregroundColor)
        #expect(runs == [ColorToken.stReview.color, DiffLineKind.added.textInk.color])
    }

    @Test("server text in a diff line is never read as Markdown or a link")
    func diffLineIsPlainText() {
        let text = "**bold** [a link](https://example.com) `code`"
        let line = DiffLineContent(kind: .context, newNumber: 1, spans: [HighlightedSpan(text)])
        let attributed = line.attributedText()

        #expect(String(attributed.characters) == text)
        #expect(attributed.runs.allSatisfy { $0.link == nil && $0.inlinePresentationIntent == nil })
    }

    @Test("every colour token names an asset", arguments: ColorToken.allCases)
    func tokensNameAssets(token: ColorToken) {
        #expect(Contrast.color(token.rawValue, in: "light") != nil)
        #expect(Contrast.color(token.rawValue, in: "dark") != nil)
    }

    @Test("the shared views' text reaches 4.5:1 on its background", arguments: ["light", "dark"])
    func sharedViewContrast(theme: String) throws {
        for (foreground, background) in Self.textPairs {
            let ink = try #require(Contrast.color(foreground.rawValue, in: theme))
            let fill = try #require(Contrast.color(background.rawValue, in: theme))
            let ratio = Contrast.ratio(ink, on: fill)

            #expect(ratio >= 4.5, "\(foreground) on \(background) is \(ratio):1 in \(theme)")
        }
    }

    /// Every ink the shared views draw text in, on each background it sits on.
    private static let textPairs: [(ColorToken, ColorToken)] = {
        var pairs: [(ColorToken, ColorToken)] = []

        pairs += VerdictState.allCases.map { ($0.ink, $0.fill) }
        pairs += StatusTone.allCases.map { ($0.ink, $0.fill) }
        pairs += AgentFamily.allCases.map { ($0.ink, $0.fill) }
        pairs += [(.ink, .stDoingSoft), (.ink, .surface), (.stBlocked, .surface), (.ink3, .surface), (.ink2, .surface)]
        // The review's checks rows: each result in its tone on the card, such
        // as "1 minor" in stDoing, which the iOS 27 audit once failed on an
        // iPhone 18 Pro (W2801).
        pairs += [(.stDone, .surface), (.stDoing, .surface)]
        // The selected sidebar row on an iPad.
        pairs += [(.strideOrangeInk, .strideOrangeSoft)]
        // The Now screen's notices after a card's action.
        pairs += [(.ink, .stDoneSoft), (.ink, .stBlockedSoft)]
        // The reply and attempt sheets' problems, on the screen's background.
        pairs += [(.stBlocked, .bg), (.ink2, .bg), (.ink3, .bg), (.ink, .bg)]
        // The Approved toast: its text and Next in surface, and its checkmark,
        // on ink.
        pairs += [(.surface, .ink), (.stDoneSoft, .ink)]
        // The Request changes sheet draws Cancel and Send in strideOrangeInk,
        // the meta line in ink3, and the field's label and the chips in ink2,
        // all on surface: ink3 and ink2 are paired with surface above, and
        // strideOrangeInk is the diff's atom colour on a context line below.

        for kind in DiffLineKind.allCases {
            let background = kind.background ?? .surface
            pairs += [(kind.numberInk, background), (kind.textInk, background)]
            pairs += HighlightClass.allCases.compactMap(\.ink).map { ($0, background) }
        }

        return pairs
    }()
}
