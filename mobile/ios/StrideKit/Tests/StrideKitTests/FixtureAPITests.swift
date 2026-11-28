import Foundation
import HTTPTypes
import os
import Testing

@testable import StrideKit

struct FixtureAPITests {
    @Test("answers the operations that have no body")
    func noContent() async throws {
        let api = FixtureAPI().client

        _ = try await api.signOutCurrentDevice().noContent
        _ = try await api.revokeMyDevice(path: .init(id: 1)).noContent
    }

    @Test("a replaced body is served for its own operation only")
    func replacedBody() async throws {
        let data = Data(#"{"data": []}"#.utf8)
        let api = FixtureAPI(replacing: [Operations.ListMyBoards.id: data]).client

        #expect(try await api.listMyBoards().ok.body.json.data.isEmpty)
        #expect(try await api.listMyDecisions().ok.body.json.data.items.isEmpty == false)
    }

    @Test("an answer picked at send time wins over a replacement, and nil falls through")
    func answeredAtSendTime() async throws {
        let empty = Data(#"{"data": []}"#.utf8)
        let emptyNext = OSAllocatedUnfairLock(initialState: false)
        let api = FixtureAPI(
            replacing: [Operations.ListMyBoards.id: Data("{}".utf8)],
            answering: { id in
                guard id == Operations.ListMyBoards.id || id == Operations.ListMyReviews.id else { return nil }
                return emptyNext.withLock { $0 } ? empty : nil
            }
        ).client

        #expect(try await api.listMyReviews().ok.body.json.data.isEmpty == false)
        emptyNext.withLock { $0 = true }
        #expect(try await api.listMyReviews().ok.body.json.data.isEmpty)
        #expect(try await api.listMyBoards().ok.body.json.data.isEmpty)
        #expect(try await api.listMyDecisions().ok.body.json.data.items.isEmpty == false)
    }

    @Test("a body that does not match the contract fails")
    func wrongBody() async {
        let api = FixtureAPI(replacing: [Operations.ListMyBoards.id: Data("{}".utf8)]).client

        await #expect(throws: (any Error).self) {
            _ = try await api.listMyBoards().ok.body.json
        }
    }

    @Test("an unreachable operation fails as if the device were offline, and only that one")
    func unreachable() async throws {
        let api = FixtureAPI(unreachable: [Operations.GetMe.id]).client

        await #expect(throws: (any Error).self) { _ = try await api.getMe() }
        do {
            _ = try await api.getMe()
        } catch {
            #expect(SignInError(classifying: error) == .network)
        }
        #expect(try await api.listMyBoards().ok.body.json.data.isEmpty == false)
    }

    @Test("a device that goes offline fails every request after it, as the network would")
    func goesOffline() async throws {
        let offline = OSAllocatedUnfairLock(initialState: false)
        let api = FixtureAPI(isOffline: { offline.withLock { $0 } }).client
        #expect(try await api.getMe().ok.body.json.data.user.displayName.isEmpty == false)

        offline.withLock { $0 = true }

        do {
            _ = try await api.listMyBoards()
            Issue.record("an offline request answered")
        } catch {
            #expect(SignInError(classifying: error) == .network)
        }
    }

    @Test("the locked plan answers me for a person without the Organization plan")
    func lockedPlan() async throws {
        let api = FixtureAPI(replacing: try FixtureAPI.lockedPlan).client
        let me = try await api.getMe().ok.body.json.data
        let fixture = try await FixtureAPI().client.getMe().ok.body.json.data

        #expect(me.appUnlocked == false)
        #expect(fixture.appUnlocked)
        #expect(me.user.id == fixture.user.id)
    }

    @Test("throws for an operation with no fixture")
    func missingFixture() {
        #expect(throws: (any Error).self) { try FixtureAPI.fixture(named: "noSuchOperation") }
    }

    @MainActor
    @Test("a view model loads from the fixtures through the protocol")
    func viewModel() async throws {
        let model = ExampleViewModel(api: FixtureAPI().client)

        try await model.load()

        #expect(model.titles.first == "Add a sign-in screen")
    }

    @Test("a status override answers with that status, and the send listener hears the body")
    func statusAndSend() async throws {
        let heard = OSAllocatedUnfairLock<[(String, Data?)]>(initialState: [])
        let refusal = Data(#"{"error": "not_movable", "message": "moved"}"#.utf8)
        let locked = Data(#"{"error": "plan_required", "feature": "mobile_app", "message": "locked"}"#.utf8)
        let api = FixtureAPI(
            replacing: [Operations.MoveMyTaskToBacklog.id: refusal, Operations.CommentOnMyTask.id: locked],
            statuses: [
                Operations.MoveMyTaskToBacklog.id: 422,
                Operations.CommentOnMyTask.id: 403,
                Operations.GetMyGoalAfterGoal.id: 404,
            ],
            onSend: { id, body in heard.withLock { $0.append((id, body)) } }
        ).client

        let moved = try await api.moveMyTaskToBacklog(path: .init(id: 1))
        #expect(try moved.unprocessableContent.body.json.message == "moved")

        let comment = try await api.commentOnMyTask(path: .init(id: 1), body: .json(.init(content: "返信")))
        guard case .forbidden = comment else {
            Issue.record("expected 403, got \(comment)")
            return
        }

        // A status whose schema needs a body, sent without one, cannot be decoded.
        await #expect(throws: (any Error).self) { try await api.getMyGoalAfterGoal(path: .init(id: 1)) }

        let sent = heard.withLock { $0 }
        #expect(sent.map(\.0) == [Operations.MoveMyTaskToBacklog.id, Operations.CommentOnMyTask.id, Operations.GetMyGoalAfterGoal.id])
        #expect(sent.last?.1 == nil)
        let body = try #require(sent.dropFirst().first?.1)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["content"] as? String == "返信")
    }

    @Test("the request listener hears each request's headers and body, even one that then fails offline")
    func requestHeaders() async throws {
        let heard = OSAllocatedUnfairLock<[(String, String?)]>(initialState: [])
        let bodies = OSAllocatedUnfairLock<[Data?]>(initialState: [])
        let key = HTTPField.Name("Idempotency-Key")!
        let api = FixtureAPI(
            unreachable: [Operations.ApproveMyReview.id],
            onRequest: { id, headers, body in
                heard.withLock { $0.append((id, headers[key])) }
                bodies.withLock { $0.append(body) }
            }
        ).client
        let body = Components.Schemas.ApproveReviewRequest(nonce: "N", signature: "S")

        await #expect(throws: (any Error).self) {
            try await api.approveMyReview(path: .init(taskId: 4812), headers: .init(idempotencyKey: "K-1"), body: .json(body))
        }
        _ = try await api.listMyReviews().ok

        let sent = heard.withLock { $0 }
        #expect(sent.map(\.0) == [Operations.ApproveMyReview.id, Operations.ListMyReviews.id])
        #expect(sent.map(\.1) == ["K-1", nil])
        let lost = try #require(bodies.withLock { $0.first } ?? nil)
        let json = try #require(try JSONSerialization.jsonObject(with: lost) as? [String: Any])
        #expect(json["nonce"] as? String == "N")
        #expect(bodies.withLock { $0.last } == .some(nil))
    }

    @Test(
        "a held request answers only after its hold returns, so another call finishes first",
        .timeLimit(.minutes(1))
    )
    func holdsARequest() async throws {
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let finished = OSAllocatedUnfairLock<[String]>(initialState: [])
        let api = FixtureAPI(hold: { id in
            guard id == Operations.ListMyReviews.id else { return }
            entered.continuation.yield()
            for await _ in release.stream { break }
        }).client

        let held = Task {
            _ = try await api.listMyReviews().ok
            finished.withLock { $0.append("reviews") }
        }
        // A fixture that never holds never says it entered, and the time
        // limit fails the test.
        for await _ in entered.stream { break }
        _ = try await api.listMyBoards().ok
        finished.withLock { $0.append("boards") }
        release.continuation.yield()
        try await held.value

        #expect(finished.withLock { $0 } == ["boards", "reviews"])
    }

    @Test("the example approval carries its challenge, and prints as redacted")
    func exampleApproval() async throws {
        let api = FixtureAPI().client
        let challenge = try await api.createMyReviewApprovalChallenge(
            path: .init(taskId: 4812),
            body: .json(.init(reviewFingerprint: String(repeating: "a", count: 64)))
        ).created.body.json.data

        let approval = try SignedApproval.example(for: challenge)

        #expect(approval.taskID == 4812)
        #expect(approval.nonce == challenge.nonce)
        #expect(approval.reviewRequestedAt == challenge.reviewRequestedAt)
        #expect(String(describing: approval) == "SignedApproval(redacted)")
    }
}
