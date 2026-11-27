import Foundation
import os
import Testing

@testable import Stride
@testable import StrideKit

/// What a Now card's buttons do: moving a task to Backlog, replying, viewing a
/// failed hook's attempt and opening another screen, online and offline.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NowActionsTests {
    private static let move = Operations.MoveMyTaskToBacklog.id
    private static let comment = Operations.CommentOnMyTask.id
    private static let attempt = Operations.GetMyGoalAfterGoal.id
    private static let list = Operations.ListMyDecisions.id

    @Test("Move to Backlog calls the move endpoint and clears the card")
    func moveClearsCard() async throws {
        let (actions, now, sent) = await Self.screen()
        let released = try Self.card("released-9001", in: now)

        #expect(actions.perform(.moveToBacklog, on: released) == nil)
        await waitUntil { actions.notice != nil }

        #expect(actions.notice == .movedToBacklog)
        #expect(!now.cards.contains { $0.id == released.id })
        #expect(now.cards.count == 4)
        #expect(sent.operations == [Self.list, Self.move])
        #expect(!actions.isMoving(released))
    }

    @Test("a second tap on Move to Backlog sends one move")
    func doubleTapMovesOnce() async throws {
        let (actions, now, sent) = await Self.screen()
        let expired = try Self.card("claim_expired-4814", in: now)

        _ = actions.perform(.moveToBacklog, on: expired)
        _ = actions.perform(.moveToBacklog, on: expired)
        await waitUntil { actions.notice != nil }

        #expect(sent.operations.filter { $0 == Self.move }.count == 1)
        #expect(actions.notice == .movedToBacklog)
    }

    @Test("a 409 because the task moved shows the current state")
    func conflictReloads() async throws {
        let conflict = Data(#"{"error": "conflict", "message": "A task was moved by someone else at the same time."}"#.utf8)
        let (actions, now, sent) = await Self.screen(replacing: [Self.move: conflict], statuses: [Self.move: 409])
        let released = try Self.card("released-9001", in: now)

        _ = actions.perform(.moveToBacklog, on: released)
        await waitUntil { actions.notice != nil && sent.operations.count == 3 }

        #expect(actions.notice == .taskMoved)
        #expect(actions.notice?.isProblem == true)
        // The list was asked for again, and shows what the server holds now.
        #expect(sent.operations == [Self.list, Self.move, Self.list])
        #expect(now.cards.contains { $0.id == released.id })
    }

    @Test("a task that is not movable any more shows the current state")
    func notMovableReloads() async throws {
        let refusal = Data(#"{"error": "not_movable", "message": "Only work and defect tasks move."}"#.utf8)
        let (actions, now, sent) = await Self.screen(replacing: [Self.move: refusal], statuses: [Self.move: 422])

        await actions.moveToBacklog(try Self.card("claim_expired-4814", in: now))

        #expect(actions.notice == .taskMoved)
        #expect(sent.operations == [Self.list, Self.move, Self.list])
    }

    @Test("access removed before Move says so and keeps the card")
    func forbiddenMove() async throws {
        let forbidden = Data(#"{"error": "forbidden", "message": "Read-only access."}"#.utf8)
        let (actions, now, _) = await Self.screen(replacing: [Self.move: forbidden], statuses: [Self.move: 403])
        let released = try Self.card("released-9001", in: now)

        await actions.moveToBacklog(released)

        #expect(actions.notice == .notAllowed)
        #expect(now.cards.contains { $0.id == released.id })
    }

    @Test("Reply posts a comment")
    func replyPosts() async throws {
        let (actions, now, sent) = await Self.screen()
        let released = try Self.card("released-9001", in: now)

        #expect(actions.perform(.reply, on: released) == nil)
        let reply = try Self.reply(in: actions)
        #expect(reply.taskID == 4813)
        reply.text = "Keep the old column for now."
        await actions.send(reply)

        #expect(actions.sheet == nil)
        #expect(actions.notice == .replySent)
        #expect(sent.operations == [Self.list, Self.comment])
        #expect(try sent.content(of: Self.comment) == "Keep the old column for now.")
    }

    @Test("a reply in Japanese is sent as typed, without the space around it")
    func japaneseReply() async throws {
        let (actions, now, sent) = await Self.screen()
        _ = actions.perform(.reply, on: try Self.card("released-9001", in: now))
        let reply = try Self.reply(in: actions)

        reply.text = "  古い列は次のリリースで削除します。\n"
        await actions.send(reply)

        #expect(try sent.content(of: Self.comment) == "古い列は次のリリースで削除します。")
    }

    @Test("an empty reply cannot be sent", arguments: ["", "   ", "\n\t "])
    func emptyReply(text: String) async throws {
        let (actions, now, sent) = await Self.screen()
        _ = actions.perform(.reply, on: try Self.card("released-9001", in: now))
        let reply = try Self.reply(in: actions)

        reply.text = text
        #expect(!reply.canSend)
        await actions.send(reply)

        #expect(sent.operations == [Self.list])
        #expect(actions.sheet != nil)
        #expect(actions.notice == nil)
    }

    @Test("a reply over the limit cannot be sent")
    func longReply() async throws {
        let (actions, now, _) = await Self.screen()
        _ = actions.perform(.reply, on: try Self.card("released-9001", in: now))
        let reply = try Self.reply(in: actions)

        reply.text = String(repeating: "a", count: ReplyModel.limit)
        #expect(reply.canSend)
        reply.text += "a"
        #expect(reply.isTooLong)
        #expect(!reply.canSend)
    }

    @Test("a refused reply stays open and says why")
    func refusedReply() async throws {
        let locked = Data(#"{"error": "plan_required", "feature": "mobile_app", "message": "The app needs a plan."}"#.utf8)
        let (actions, now, _) = await Self.screen(replacing: [Self.comment: locked], statuses: [Self.comment: 403])
        _ = actions.perform(.reply, on: try Self.card("released-9001", in: now))
        let reply = try Self.reply(in: actions)

        reply.text = "Done."
        await actions.send(reply)

        #expect(reply.problem == .notAllowed)
        #expect(actions.sheet != nil)
        #expect(actions.notice == nil)
    }

    @Test("offline disables every action with Needs a connection")
    func offlineDisables() async throws {
        let offline = OSAllocatedUnfairLock(initialState: false)
        let (actions, now, sent) = await Self.screen(isOffline: { offline.withLock { $0 } })
        // A reply opened while online cannot be sent once the device is offline.
        _ = actions.perform(.reply, on: try Self.card("released-9001", in: now))
        let reply = try Self.reply(in: actions)
        reply.text = "Done."
        actions.sheet = nil

        offline.withLock { $0 = true }
        await now.load()
        #expect(actions.isOffline)

        for card in now.cards {
            for action in card.actions {
                #expect(actions.perform(action, on: card) == nil, "\(action) on \(card.id) acted offline")
            }
        }
        await actions.moveToBacklog(try Self.card("claim_expired-4814", in: now))
        #expect(!reply.canSend)

        #expect(actions.sheet == nil)
        #expect(actions.notice == nil)
        #expect(actions.moving.isEmpty)
        #expect(sent.operations == [Self.list])
        #expect(now.cards.count == 5)
        // The buttons and the reply sheet say why they wait.
        #expect(LocalizedStringResource.nowNeedsConnection.resolved(in: Locale(identifier: "en")) == "Needs a connection")
    }

    @Test("View attempt shows exit code and duration only")
    func viewAttempt() async throws {
        let (actions, now, sent) = await Self.screen()
        let hook = try Self.card("hook_failed-4815", in: now)

        #expect(actions.perform(.viewAttempt, on: hook) == nil)
        guard case .attempt(let attempt) = actions.sheet else {
            Issue.record("no attempt sheet")
            return
        }
        #expect(attempt.goalID == 4815)
        #expect(attempt.state == .loading)
        await attempt.load()

        let shown = HookAttempt(exitCode: 1, duration: .seconds(4))
        #expect(attempt.state == .loaded(shown))
        #expect(sent.operations == [Self.list, Self.attempt])
        // Nothing else of the attempt, its output least of all, reaches the sheet.
        #expect(Mirror(reflecting: shown).children.map(\.label) == ["exitCode", "duration"])
        let english = Locale(identifier: "en")
        #expect(shown.exitCodeText(in: english) == "1")
        #expect(shown.durationText(in: english) == Duration.seconds(4).hookText(in: english))
    }

    @Test("an attempt the server does not report says so")
    func attemptNotReported() async throws {
        let blank = Data(#"""
        {"data": {"goal_id": 4815, "identifier": "G88", "status": "pending", "exit_code": null,
                  "duration_ms": null, "reported_at": null, "failed": true}}
        """#.utf8)
        let (actions, now, _) = await Self.screen(replacing: [Self.attempt: blank])
        _ = actions.perform(.viewAttempt, on: try Self.card("hook_failed-4815", in: now))
        guard case .attempt(let attempt) = actions.sheet else {
            Issue.record("no attempt sheet")
            return
        }

        await attempt.load()

        let english = Locale(identifier: "en")
        let missing = LocalizedStringResource.nowAttemptNotReported.resolved(in: english)
        #expect(attempt.state == .loaded(HookAttempt(exitCode: nil, duration: nil)))
        #expect(HookAttempt(exitCode: nil, duration: nil).exitCodeText(in: english) == missing)
        #expect(HookAttempt(exitCode: nil, duration: nil).durationText(in: english) == missing)
    }

    @Test("an attempt that cannot be fetched shows it is unavailable")
    func attemptUnavailable() async throws {
        let (actions, now, _) = await Self.screen(statuses: [Self.attempt: 404])
        _ = actions.perform(.viewAttempt, on: try Self.card("hook_failed-4815", in: now))
        guard case .attempt(let attempt) = actions.sheet else {
            Issue.record("no attempt sheet")
            return
        }

        await attempt.load()

        #expect(attempt.state == .unavailable)
    }

    @Test("opening a review, the web page or the backlog goes to the router")
    func navigationActions() async throws {
        let (actions, now, sent) = await Self.screen()

        let review = try Self.card("review-4812", in: now)
        #expect(actions.perform(.openReview, on: review) == .push(.review(4812)))
        let web = try #require(review.webURL)
        #expect(actions.perform(.openOnWeb, on: review) == .web(web))
        let ready = try Self.card("ready_empty-12", in: now)
        #expect(actions.perform(.openBacklog, on: ready) == .show(.board("12", column: .backlog), on: .boards))

        #expect(actions.sheet == nil)
        #expect(sent.operations == [Self.list])
    }

    @Test("a sign-out drops the sheet, the notice and an answer on its way")
    func forgetDropsAll() async throws {
        let (actions, now, _) = await Self.screen()
        _ = actions.perform(.reply, on: try Self.card("released-9001", in: now))
        actions.notice = .replySent

        actions.forget()

        #expect(actions.sheet == nil)
        #expect(actions.notice == nil)
        #expect(actions.moving.isEmpty)
    }

    // MARK: Helpers

    /// The Now screen after its first list, with the operations the client sent.
    private static func screen(
        replacing replacements: [String: Data] = [:],
        statuses: [String: Int] = [:],
        isOffline: @escaping @Sendable () -> Bool = { false }
    ) async -> (NowActions, NowModel, SentOperations) {
        let sent = SentOperations()
        let api = FixtureAPI(replacing: replacements, statuses: statuses, isOffline: isOffline) { operation, body in
            sent.record(operation, body)
        }.client
        let now = NowModel(api: api)
        await now.load()
        return (NowActions(api: api, now: now), now, sent)
    }

    private static func card(_ id: NowCard.ID, in now: NowModel) throws -> NowCard {
        try #require(now.cards.first { $0.id == id }, "no card \(id)")
    }

    private static func reply(in actions: NowActions) throws -> ReplyModel {
        guard case .reply(let reply) = actions.sheet else { throw MissingSheet() }

        return reply
    }

    private struct MissingSheet: Error {}
}

/// The operations a `FixtureAPI` sent, with their bodies, behind a lock.
final class SentOperations: Sendable {
    private let lock = OSAllocatedUnfairLock<[(operation: String, body: Data?)]>(initialState: [])

    func record(_ operation: String, _ body: Data?) {
        lock.withLock { $0.append((operation, body)) }
    }

    var operations: [String] {
        lock.withLock { $0.map(\.operation) }
    }

    /// The `content` of the last body sent for `operation`.
    func content(of operation: String) throws -> String? {
        let body = lock.withLock { $0.last { $0.operation == operation }?.body }
        let data = try #require(body)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return json["content"] as? String
    }
}
