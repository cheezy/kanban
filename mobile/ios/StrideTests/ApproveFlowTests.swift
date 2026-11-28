import Foundation
import os
import Testing

@testable import Stride
@testable import StrideKit

/// Approve on the review screen: the challenge, the signature, the one resend
/// with the same idempotency key, and what each refusal shows.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ApproveFlowTests {
    private nonisolated static let challengeID = Operations.CreateMyReviewApprovalChallenge.id
    private nonisolated static let approveID = Operations.ApproveMyReview.id
    private nonisolated static let reviewID = Operations.GetMyReview.id

    /// A signer that throws instead of signing.
    private struct FailingSigner: ApprovalSigning {
        let error: ApprovalSignerError

        func sign(
            reason: String,
            web: any WebAuthenticating,
            challenge: @escaping @Sendable () async throws -> Components.Schemas.ApprovalChallenge
        ) async throws -> ApprovalSigner.Outcome {
            throw error
        }
    }

    private static func loaded(
        _ fixtures: FixtureAPI,
        signer: any ApprovalSigning = StubApprovalSigning.match,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> ReviewModel {
        let api = fixtures.client
        let model = ReviewModel(taskID: 4812, api: api, approvals: ApproveFlow(api: api, signer: signer))
        await model.load()
        try #require(model.state == .review, sourceLocation: sourceLocation)
        try #require(model.canApprove, sourceLocation: sourceLocation)
        return model
    }

    private static var web: StubWebAuthenticator { StubWebAuthenticator(outcome: .allow) }

    private static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private static func rejected(_ reason: String) throws -> Data {
        try json(["error": "signature_rejected", "reason": reason, "message": "Request a new challenge."])
    }

    private static func conflictBody(_ error: String) throws -> Data {
        try json([
            "error": error,
            "message": "This review has already been decided.",
            "review": [
                "task_id": 4812,
                "identifier": "W101",
                "review_status": "approved",
                "review_requested_at": "2026-11-18T09:30:00Z",
                "reviewed_at": "2026-11-18T09:40:00Z",
                "reviewed_by": "Sam Rivera",
            ] as [String: Any],
        ])
    }

    /// A request body as JSON, or nil when there was none.
    private static func object(_ body: Data??) throws -> [String: Any] {
        let data = try #require(body ?? nil)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func date(_ value: Any?) -> Date? {
        (value as? String).flatMap { try? Date($0, strategy: .iso8601) }
    }

    private static func english(_ resource: LocalizedStringResource) -> String {
        resource.resolved(in: Locale(identifier: "en"))
    }

    // MARK: Approving

    @Test("approves and says which tasks can start")
    func approves() async throws {
        let heard = HeardRequests()
        let model = try await Self.loaded(heard.fixtures())

        await model.approve(web: Self.web)

        #expect(model.approved == ["W102", "W103"])
        #expect(model.approveProblem == nil)
        #expect(model.isApproving == false)
        #expect(model.canApprove == false)
        let message = try #require(model.approvedMessage(in: Locale(identifier: "en")))
        #expect(Self.english(message) == "Approved. W102 and W103 can start.")
        #expect(Array(heard.operations.suffix(2)) == [Self.challengeID, Self.approveID])
        let key = try #require(heard.keys.first ?? nil)
        #expect(UUID(uuidString: key) != nil)
    }

    /// The values are compared as booleans, so a failure never prints the
    /// nonce or the signature.
    @Test("the challenge is bound to the review shown, and the approval answers it")
    func requestBodies() async throws {
        let heard = HeardRequests()
        let model = try await Self.loaded(heard.fixtures())
        let content = try #require(model.content)
        let requestedAt = try #require(content.reviewRequestedAt)
        let issued = try await FixtureAPI().client.createMyReviewApprovalChallenge(
            path: .init(taskId: content.taskID),
            body: .json(.init(reviewFingerprint: content.reviewFingerprint))
        ).created.body.json.data.nonce

        await model.approve(web: Self.web)

        let challenge = try Self.object(heard.bodies(of: Self.challengeID).last)
        let approval = try Self.object(heard.bodies(of: Self.approveID).first)
        let boundToFingerprint = challenge["review_fingerprint"] as? String == content.reviewFingerprint
        #expect(boundToFingerprint)
        #expect(Self.date(challenge["review_requested_at"]) == requestedAt)
        #expect(Self.date(approval["review_requested_at"]) == requestedAt)
        let answersTheChallenge = approval["nonce"] as? String == issued
        #expect(answersTheChallenge)
        let isSigned = (approval["signature"] as? String)?.isEmpty == false
        #expect(isSigned)
    }

    @Test("once approved, a refresh asks nothing and the review is no longer cached")
    func approvedStays() async throws {
        let container = try TemporaryContainer()
        let cache = Cache(container: container.url)
        let heard = HeardRequests()
        let api = heard.fixtures().client
        let model = ReviewModel(
            taskID: 4812, api: api, cache: cache, approvals: ApproveFlow(api: api, signer: StubApprovalSigning.match)
        )
        await model.load()
        #expect(try await cache.cached(.review(taskID: 4812)) != nil)
        #expect(model.showsDecisionNotice == false)

        await model.approve(web: Self.web)
        #expect(model.showsDecisionNotice)
        #expect(try await cache.cached(.review(taskID: 4812)) == nil)

        let asked = heard.operations.count
        await model.load()
        #expect(heard.operations.count == asked)
        #expect(model.state == .review)
        #expect(model.approved == ["W102", "W103"])
        withExtendedLifetime(container) {}
    }

    @Test(
        "a load on its way when the approval lands neither hides it nor caches the review again",
        arguments: [404, nil] as [Int?]
    )
    func loadOnItsWay(status: Int?) async throws {
        let container = try TemporaryContainer()
        let cache = Cache(container: container.url)
        let heard = HeardRequests()
        let gate = RequestGate()
        let api = heard.fixtures(
            // The late load answers as the server would after the approval:
            // gone, or the fixture's review as it was (nil).
            status: { id in id == Self.reviewID && heard.approvals > 0 ? status : nil },
            hold: { id in
                if id == Self.reviewID, heard.operations.filter({ $0 == Self.reviewID }).count == 2 { await gate.wait() }
            }
        ).client
        let model = ReviewModel(
            taskID: 4812, api: api, cache: cache, approvals: ApproveFlow(api: api, signer: StubApprovalSigning.match)
        )
        await model.load()

        let refresh = Task { await model.load() }
        await gate.untilHeld()
        await model.approve(web: Self.web)
        gate.open()
        await refresh.value

        #expect(model.state == .review)
        #expect(model.approved == ["W102", "W103"])
        #expect(model.isOffline == false)
        #expect(try await cache.cached(.review(taskID: 4812)) == nil)
        withExtendedLifetime(container) {}
    }

    @Test("an approval that held nothing up says Approved.")
    func approvedAlone() async throws {
        let review = try DecisionFixtures.reviewData { $0["holds_up"] = [String]() }
        let model = try await Self.loaded(FixtureAPI(replacing: [Operations.GetMyReview.id: review]))

        await model.approve(web: Self.web)

        #expect(model.approved == [])
        #expect(Self.english(try #require(model.approvedMessage(in: Locale(identifier: "en")))) == "Approved.")
    }

    @Test("a lost approval is sent once more with the same key and body")
    func resendsWithTheSameKey() async throws {
        let heard = HeardRequests()
        let fixtures = heard.fixtures(
            isOffline: { heard.operations.last == Self.approveID && heard.approvals == 1 }
        )
        let model = try await Self.loaded(fixtures)

        await model.approve(web: Self.web)

        #expect(model.approved == ["W102", "W103"])
        // A require, so a build that sends once fails here rather than
        // crashing the test host on the index below.
        try #require(heard.keys.count == 2)
        #expect(heard.keys[0] != nil && heard.keys[0] == heard.keys[1])
        #expect(heard.operations.filter { $0 == Self.challengeID }.count == 1)
        let sent = heard.bodies(of: Self.approveID)
        let sameBody = sent.count == 2 && sent[0] != nil && sent[0] == sent[1]
        #expect(sameBody)
    }

    @Test("two lost approvals say it failed, and a new tap starts again with a new key")
    func twoLostApprovals() async throws {
        let heard = HeardRequests()
        let fixtures = heard.fixtures(
            isOffline: { heard.operations.last == Self.approveID && heard.approvals <= 2 }
        )
        let model = try await Self.loaded(fixtures)

        await model.approve(web: Self.web)
        #expect(model.approveProblem == .failed)
        #expect(model.approved == nil)
        #expect(model.canApprove)

        await model.approve(web: Self.web)
        #expect(model.approved == ["W102", "W103"])
        try #require(heard.keys.count == 3)
        #expect(heard.keys[2] != heard.keys[0])
        #expect(heard.operations.filter { $0 == Self.challengeID }.count == 2)
    }

    // MARK: Refusals

    @Test(
        "a refused signature says why and leaves Approve on",
        arguments: [("expired", ApproveProblem.expired), ("reused", .expired), ("invalid", .refused), ("missing", .refused)]
    )
    func refusedSignature(reason: String, problem: ApproveProblem) async throws {
        let model = try await Self.loaded(
            FixtureAPI(replacing: [Self.approveID: try Self.rejected(reason)], statuses: [Self.approveID: 422])
        )

        await model.approve(web: Self.web)

        #expect(model.approveProblem == problem)
        #expect(model.approved == nil)
        #expect(model.canApprove)
        #expect(model.showsDecisionNotice)
        model.dismissApproveProblem()
        #expect(model.approveProblem == nil)
        #expect(model.showsDecisionNotice == false)
    }

    @Test("an answer that reached the server but could not be read is not sent again")
    func unreadableAnswer() async throws {
        let heard = HeardRequests()
        let model = try await Self.loaded(
            heard.fixtures(replacing: [Self.approveID: Data("not json".utf8)], statuses: [Self.approveID: 200])
        )

        await model.approve(web: Self.web)

        #expect(heard.approvals == 1)
        #expect(model.approveProblem == .failed)
        #expect(model.approved == nil)
    }

    @Test("an approval that could not be made says it failed")
    func approvalFailed() async throws {
        let body = try Self.json(["error": "approval_failed", "reason": "column_not_found"])
        let model = try await Self.loaded(FixtureAPI(replacing: [Self.approveID: body], statuses: [Self.approveID: 422]))

        await model.approve(web: Self.web)

        #expect(model.approveProblem == .failed)
    }

    @Test("a 403 says the person may no longer approve", arguments: [challengeID, approveID])
    func forbidden(operation: String) async throws {
        let body = try Self.json(["error": "plan_required", "feature": "mobile_app", "message": "Upgrade to use the app."])
        let model = try await Self.loaded(FixtureAPI(replacing: [operation: body], statuses: [operation: 403]))

        await model.approve(web: Self.web)

        #expect(model.approveProblem == .notAllowed)
        #expect(Self.english(ApproveProblem.notAllowed.text) == Self.english(.nowNotAllowed))
    }

    @Test("a 409 shows Already decided", arguments: [challengeID, approveID])
    func alreadyDecided(operation: String) async throws {
        let model = try await Self.loaded(
            FixtureAPI(replacing: [operation: try Self.conflictBody("already_decided")], statuses: [operation: 409])
        )

        await model.approve(web: Self.web)

        guard case .alreadyDecided(let name, let decision, _) = model.conflict else {
            Issue.record("no Already decided: \(String(describing: model.conflict))")
            return
        }
        #expect(name == "Sam Rivera")
        #expect(decision == .approved)
        #expect(model.approved == nil)
        #expect(model.canApprove == false)
    }

    @Test("a 404 says the review is gone", arguments: [challengeID, approveID])
    func gone(operation: String) async throws {
        let body = try Self.json(["error": "Not Found"])
        let model = try await Self.loaded(FixtureAPI(replacing: [operation: body], statuses: [operation: 404]))

        await model.approve(web: Self.web)

        #expect(model.state == .unavailable)
        #expect(model.approved == nil)
    }

    @Test("a change found too large loads the review again")
    func tooLarge() async throws {
        let heard = HeardRequests()
        let body = try Self.json([
            "error": "too_large_for_phone",
            "message": "Approve it on a tablet or on the web.",
            "size": ["files": 14, "files_unknown": false, "changed_lines": 652, "truncated": false] as [String: Any],
            "limits": ["max_files": 10, "max_changed_lines": 500],
        ])
        let model = try await Self.loaded(
            heard.fixtures(replacing: [Self.challengeID: body], statuses: [Self.challengeID: 422])
        )

        await model.approve(web: Self.web)

        #expect(heard.operations.last == Operations.GetMyReview.id)
        #expect(heard.approvals == 0)
        #expect(model.state == .review)
        #expect(model.approveProblem == nil)
    }

    // MARK: Nothing sent

    /// The signer fetches the challenge before it asks for the face, so the
    /// challenge is spent; the approval is never sent.
    @Test("a face that does not match sends no approval")
    func noMatch() async throws {
        let heard = HeardRequests()
        let model = try await Self.loaded(heard.fixtures(), signer: StubApprovalSigning.nomatch)

        await model.approve(web: Self.web)

        #expect(heard.operations.contains(Self.challengeID))
        #expect(heard.approvals == 0)
        #expect(model.approved == nil)
        #expect(model.approveProblem == nil)
        #expect(model.canApprove)
    }

    @Test(
        "a signer that cannot sign says why and sends nothing",
        arguments: [
            (ApprovalSignerError.passcodeNotSet, ApproveProblem.passcodeNotSet),
            (.keyUnusable, .failed),
            (.signIn(.network), .failed),
        ]
    )
    func signerFails(error: ApprovalSignerError, problem: ApproveProblem) async throws {
        let heard = HeardRequests()
        let model = try await Self.loaded(heard.fixtures(), signer: FailingSigner(error: error))

        await model.approve(web: Self.web)

        #expect(model.approveProblem == problem)
        #expect(heard.approvals == 0)
        #expect(model.canApprove)
    }

    @Test("offline, Approve is off and nothing is sent")
    func offline() async throws {
        let heard = HeardRequests()
        let isOffline = OSAllocatedUnfairLock(initialState: false)
        let model = try await Self.loaded(
            heard.fixtures(isOffline: { isOffline.withLock { $0 } })
        )
        isOffline.withLock { $0 = true }
        await model.load()

        #expect(model.canApprove == false)
        await model.approve(web: Self.web)

        #expect(heard.operations.contains(Self.challengeID) == false)
        #expect(heard.approvals == 0)
        #expect(model.approved == nil)
    }

    @Test("a build without a signer never offers Approve, but can request changes")
    func noSigner() async throws {
        let model = ReviewModel(taskID: 4812, api: FixtureAPI().client)
        await model.load()

        #expect(model.canAct)
        #expect(model.canApprove == false)
        // Request changes signs nothing, so it needs no key.
        #expect(model.canRequestChanges)
    }

    @Test("a review to approve on a tablet or the web never offers Approve")
    func notApprovableHere() async throws {
        let review = try DecisionFixtures.reviewData { $0["approvable_here"] = false }
        let api = FixtureAPI(replacing: [Operations.GetMyReview.id: review]).client
        let model = ReviewModel(taskID: 4812, api: api, approvals: ApproveFlow(api: api, signer: StubApprovalSigning.match))
        await model.load()

        #expect(model.content?.approvableHere == false)
        #expect(model.canApprove == false)
    }
}

private extension HeardRequests {
    /// The idempotency key of each approval sent.
    var keys: [String?] { keys(of: Operations.ApproveMyReview.id) }
    var approvals: Int { keys.count }
}
