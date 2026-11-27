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

    @Test("each action goes to its screen, and the web only over https")
    func destinations() async throws {
        let cards = try await DecisionFixtures.cards()
        let review = try #require(cards.first { $0.kind == .review })
        let released = try #require(cards.first { $0.kind == .released })
        let hook = try #require(cards.first { $0.kind == .hookFailed })
        let ready = try #require(cards.first { $0.kind == .readyEmpty })
        let web = try #require(URL(string: "https://stride.example/boards/12/tasks/4812"))

        #expect(review.destination(for: .openReview) == .push(.review(4812)))
        #expect(review.destination(for: .openOnWeb) == .web(web))
        #expect(review.buttons == [.openReview, .openOnWeb])
        #expect(released.destination(for: .reply) == .push(.task("W104")))
        #expect(released.destination(for: .moveToBacklog) == .push(.task("W104")))
        #expect(hook.destination(for: .viewAttempt) == .push(.goal("W105")))
        #expect(ready.destination(for: .openBacklog) == .show(.board("12"), on: .boards))
        // The Ready card opens the backlog itself, so it has no buttons.
        #expect(ready.buttons.isEmpty)
    }

    @Test("a web address that is not https is never opened", arguments: ["http://stride.example/x", "javascript:alert(1)", "https://", "not a url"])
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
        #expect(ready.content.since == nil)
    }

    @Test("the router pushes and opens a card's screens, and hands back a web page")
    func routerOpens() throws {
        let router = AppRouter(api: nil)
        let web = try #require(URL(string: "https://stride.example/boards/12"))

        #expect(router.open(.push(.review(4812))) == nil)
        #expect(router.paths[.now] == [.review(4812)])

        #expect(router.open(.show(.board("12"), on: .boards)) == nil)
        #expect(router.selectedTab == .boards)
        #expect(router.paths[.boards] == [.board("12")])

        #expect(router.open(.web(web)) == web)
        #expect(router.paths[.now] == [.review(4812)])
    }
}
