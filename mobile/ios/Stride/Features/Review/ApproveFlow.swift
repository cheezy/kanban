import Foundation
import StrideKit

/// One approval from the app (design section 7.5): a one-time challenge bound
/// to what the screen showed, signed after Face ID, Touch ID or the passcode,
/// then sent with a new idempotency key.
///
/// A request that never reached the server is sent once more with the same
/// key and the same body (decision 18), so a lost answer cannot approve twice
/// or turn into Already decided. A new tap starts again from a new challenge,
/// so a signature is never kept or sent again later. Nothing here logs.
@MainActor
struct ApproveFlow {
    let api: any StrideAPI
    let signer: any ApprovalSigning
    /// The idempotency key for each new approval.
    var newKey: @Sendable () -> String = { UUID().uuidString }

    func approve(_ content: ReviewContent, reason: String, web: any WebAuthenticating) async -> ApproveAnswer {
        let shown = Shown(content)
        let api = api
        let signed: SignedApproval
        do {
            let outcome = try await signer.sign(reason: reason, web: web) {
                try await Self.challenge(for: shown, using: api)
            }
            guard case .signed(let approval) = outcome else { return .cancelled }
            signed = approval
        } catch let stop as Stop {
            return stop.answer
        } catch ApprovalSignerError.passcodeNotSet {
            return .problem(.passcodeNotSet)
        } catch {
            return .problem(.failed)
        }

        let body = Components.Schemas.ApproveReviewRequest(
            reviewRequestedAt: shown.reviewRequestedAt,
            nonce: signed.nonce,
            signature: signed.signature
        )
        let key = newKey()
        if let answer = await Self.send(body, key: key, shown: shown, using: api) { return answer }
        return await Self.send(body, key: key, shown: shown, using: api) ?? .problem(.failed)
    }

    // MARK: Requests

    /// What the screen showed, which the challenge is bound to.
    private struct Shown: Sendable {
        let taskID: Int
        let fingerprint: String
        let reviewRequestedAt: Date?
        let holdsUp: [String]

        init(_ content: ReviewContent) {
            taskID = content.taskID
            fingerprint = content.reviewFingerprint
            reviewRequestedAt = content.reviewRequestedAt
            holdsUp = content.holdsUp
        }
    }

    /// A challenge the server refused, carried out through the signer, which
    /// rethrows it unchanged.
    private struct Stop: Error {
        let answer: ApproveAnswer
    }

    private nonisolated static func challenge(
        for shown: Shown,
        using api: any StrideAPI
    ) async throws -> Components.Schemas.ApprovalChallenge {
        let request = Components.Schemas.ApprovalChallengeRequest(
            reviewRequestedAt: shown.reviewRequestedAt,
            reviewFingerprint: shown.fingerprint
        )
        let output: Operations.CreateMyReviewApprovalChallenge.Output
        do {
            output = try await api.createMyReviewApprovalChallenge(path: .init(taskId: shown.taskID), body: .json(request))
        } catch {
            throw Stop(answer: .problem(.failed))
        }

        switch output {
        case .created(let response):
            guard let challenge = try? response.body.json.data else { throw Stop(answer: .problem(.failed)) }
            return challenge
        case .conflict(let response):
            guard let conflict = try? response.body.json else { throw Stop(answer: .problem(.failed)) }
            throw Stop(answer: .conflict(conflict))
        case .notFound:
            throw Stop(answer: .gone)
        case .forbidden:
            throw Stop(answer: .problem(.notAllowed))
        case .unprocessableContent:
            throw Stop(answer: .tooLarge)
        default:
            throw Stop(answer: .problem(.failed))
        }
    }

    /// The server's answer, or nil when the request did not reach it.
    private nonisolated static func send(
        _ body: Components.Schemas.ApproveReviewRequest,
        key: String,
        shown: Shown,
        using api: any StrideAPI
    ) async -> ApproveAnswer? {
        let output: Operations.ApproveMyReview.Output
        do {
            output = try await api.approveMyReview(
                path: .init(taskId: shown.taskID),
                headers: .init(idempotencyKey: key),
                body: .json(body)
            )
        } catch {
            return CallFailure.isTransport(error) ? nil : .problem(.failed)
        }

        switch output {
        case .ok:
            return .approved(holdsUp: shown.holdsUp)
        case .conflict(let response):
            return (try? response.body.json).map(ApproveAnswer.conflict) ?? .problem(.failed)
        case .notFound:
            return .gone
        case .forbidden:
            return .problem(.notAllowed)
        case .unprocessableContent(let response):
            return refusal((try? response.body.json))
        default:
            return .problem(.failed)
        }
    }

    private nonisolated static func refusal(
        _ body: Operations.ApproveMyReview.Output.UnprocessableContent.Body.JsonPayload?
    ) -> ApproveAnswer {
        switch body {
        case .TooLargeForPhone:
            return .tooLarge
        case .SignatureRejected(let rejected):
            switch rejected.reason.value1 {
            case .expired, .reused: return .problem(.expired)
            case .invalid, .missing: return .problem(.refused)
            case nil: return .problem(.failed)
            }
        case .ApprovalFailed, nil:
            return .problem(.failed)
        }
    }
}
