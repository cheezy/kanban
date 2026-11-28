import Foundation
import Testing

@testable import Stride
@testable import StrideKit

/// How a server item becomes a Now card: where its buttons go, what it says,
/// and what it refuses.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NowCardTests {
    private static let english = Locale(identifier: "en")
    private static let german = Locale(identifier: "de")

    @Test("each action goes to its screen or stays on Now, and the web only to Stride")
    func destinations() async throws {
        let cards = try await DecisionFixtures.cards()
        let review = try #require(cards.first { $0.kind == .review })
        let released = try #require(cards.first { $0.kind == .released })
        let expired = try #require(cards.first { $0.kind == .claimExpired })
        let hook = try #require(cards.first { $0.kind == .hookFailed })
        let ready = try #require(cards.first { $0.kind == .readyEmpty })
        let web = try #require(URL(string: "https://www.stridelikeaboss.com/boards/12/tasks/4812"))

        #expect(review.destination(for: .openReview) == .push(.review(4812)))
        #expect(review.destination(for: .openOnWeb) == .web(web))
        #expect(review.buttons == [.openReview, .openOnWeb])
        // Replying, moving and the attempt happen on Now itself.
        for action in [NowAction.reply, .moveToBacklog] {
            #expect(released.canPerform(action))
            #expect(released.destination(for: action) == nil)
        }
        // The fixture's Released card also offers the web, which section 6.3
        // leaves off it.
        #expect(released.actions.contains(.openOnWeb))
        #expect(released.buttons == [.reply, .moveToBacklog])
        #expect(expired.buttons == [.moveToBacklog, .openOnWeb])
        #expect(hook.buttons == [.viewAttempt, .openOnWeb])
        #expect(hook.destination(for: .viewAttempt) == nil)
        #expect(ready.destination(for: .openBacklog) == .show(.board("12", column: .backlog), on: .boards))
        // The Ready card opens the backlog itself, so it has no buttons.
        #expect(ready.buttons.isEmpty)
    }

    @Test("a card with no task id offers none of the task's actions")
    func actionsNeedATask() async throws {
        let cards = try await DecisionFixtures.cards { items in
            for index in 1...3 { items[index]["task_id"] = NSNull() }
        }

        let affected = cards.filter { [.claimExpired, .hookFailed].contains($0.kind) }
        try #require(affected.count == 2)
        for card in affected {
            #expect(card.buttons == [.openOnWeb], "\(card.kind) still offers \(card.buttons)")
        }
        // A Released card has only actions on its task, so it keeps none.
        #expect(cards.first { $0.kind == .released }?.buttons == [])
    }

    @Test("a web address that is not a Stride page over https is never opened", arguments: [
        "http://www.stridelikeaboss.com/x", "https://stride.example/x", "https://www.stridelikeaboss.com.evil.example/x",
        "https://www.stridelikeaboss.com:444/x", "javascript:alert(1)", "https://", "not a url",
    ])
    func webURLRefused(address: String) async throws {
        let cards = try await DecisionFixtures.cards { $0[0]["web_url"] = address }
        let review = try #require(cards.first)

        #expect(review.webURL == nil)
        #expect(review.destination(for: .openOnWeb) == nil)
        #expect(review.buttons == [.openReview])
    }

    @Test("a review with no task id offers no Open review")
    func reviewWithoutTask() async throws {
        let cards = try await DecisionFixtures.cards { $0[0]["task_id"] = NSNull() }

        #expect(cards.first?.buttons == [.openOnWeb])
    }

    @Test("a review names its agent and its first failed note; the other kinds say theirs in their own text")
    func content() async throws {
        let cards = try await DecisionFixtures.cards()

        let review = cards[0].content
        #expect(review.agent == AgentAvatarContent(name: "Claude"))
        #expect(review.issue == "One view model reads the store directly.")
        #expect(review.holdsUp == 2)
        #expect(review.priority == .high)
        #expect(review.verdicts.count == 4)
        #expect(review.since == ISO8601DateFormatter().date(from: "2026-11-18T09:30:00Z"))
        #expect(cards.dropFirst().allSatisfy { $0.content.agent == nil })
        #expect(cards[0].body(in: Self.english) == nil)
    }

    @Test("a released card quotes the agent's reason in the locale's quotation marks")
    func releasedReason() async throws {
        let released = try #require(try await DecisionFixtures.cards().first { $0.kind == .released })

        #expect(released.body(in: Self.english) == "“Needs a design decision on cache size”")
        #expect(released.body(in: Self.german) == "„Needs a design decision on cache size“")
        #expect(released.detail == .released(reason: "Needs a design decision on cache size", agent: AgentAvatarContent(name: "Claude")))
    }

    @Test("an expired claim says how long the agent held it, or only that it ran out")
    func claimExpired() async throws {
        let unnamed = try #require(try await DecisionFixtures.cards().first { $0.kind == .claimExpired })
        #expect(unnamed.body(in: Self.english) == "Its claim ran out with no update. It is back in Ready for another agent.")

        let cards = try await DecisionFixtures.cards { items in
            var summary = items[2]["summary"] as? [String: Any] ?? [:]
            summary["agent"] = "Codex"
            items[2]["summary"] = summary
        }
        let named = try #require(cards.first { $0.kind == .claimExpired })
        #expect(named.detail == .claimExpired(agent: "Codex", minutes: 60))
        #expect(named.body(in: Self.english) == "Codex held it for 60 minutes with no update. It is back in Ready for another agent.")
        #expect(named.body(in: Self.german)?.hasPrefix("Codex hatte sie 60 Minuten") == true)
    }

    @Test("an expiry before the claim gives no minutes")
    func claimBackwards() async throws {
        let cards = try await DecisionFixtures.cards { items in
            items[2]["details"] = ["claimed_at": "2026-11-19T16:00:00Z", "expired_at": "2026-11-19T15:00:00Z"]
        }

        #expect(cards.first { $0.kind == .claimExpired }?.detail == .claimExpired(agent: nil, minutes: nil))
    }

    @Test("a failed hook says its exit code and how long it ran")
    func hookFailed() async throws {
        let hook = try #require(try await DecisionFixtures.cards().first { $0.kind == .hookFailed })
        let english = try #require(hook.body(in: Self.english))

        #expect(english.hasPrefix("after_goal failed · exit 1 · "))
        #expect(english.contains("48"))
        #expect(hook.body(in: Self.german)?.hasPrefix("after_goal fehlgeschlagen · Exit 1 · ") == true)

        let bare = try await DecisionFixtures.cards { $0[3]["details"] = ["exit_code": NSNull(), "duration_ms": NSNull()] }
        #expect(bare.first { $0.kind == .hookFailed }?.body(in: Self.english) == "after_goal failed")
    }

    @Test("the Ready card names its board and counts its agents and backlog")
    func readyEmpty() async throws {
        let ready = try #require(try await DecisionFixtures.cards().first { $0.kind == .readyEmpty })

        #expect(ready.readyHeading(in: Self.english) == "Ready is empty · Stride Development")
        #expect(ready.body(in: Self.english) == "2 agents idle. 5 tasks in Backlog to choose from.")
        #expect(ready.readyHeading(in: Self.german) == "Bereit ist leer · Stride Development")
        // Japanese puts no space between sentences.
        #expect(ready.body(in: Locale(identifier: "ja")) == "2 体のエージェントが待機中。バックログに選べるタスクが 5 件あります。")
        #expect(ready.content.since == nil)
    }

    @Test("the router pushes and opens a card's screens, and hands back a web page")
    func routerOpens() throws {
        let router = AppRouter(api: nil)
        let web = try #require(URL(string: "https://www.stridelikeaboss.com/boards/12"))

        #expect(router.open(.push(.review(4812))) == nil)
        #expect(router.paths[.now] == [.review(4812)])

        #expect(router.open(.show(.board("12", column: .backlog), on: .boards)) == nil)
        #expect(router.selectedTab == .boards)
        #expect(router.paths[.boards] == [.board("12", column: .backlog)])

        #expect(router.open(.web(web)) == web)
        #expect(router.paths[.now] == [.review(4812)])
    }
}
