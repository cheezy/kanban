/// What the approve request sends (`ApproveReviewRequest`), for the challenge
/// that was signed.
///
/// It prints as `SignedApproval(redacted)`: the signature and the nonce must
/// never reach a log.
public struct SignedApproval: Equatable, Sendable {
    /// The task the challenge named, which is the task to approve.
    public let taskID: Int

    /// The challenge's nonce.
    public let nonce: String

    /// The challenge's `review_requested_at`, as it was signed: an ISO 8601 UTC
    /// timestamp, or the empty string for a task without one.
    public let reviewRequestedAt: String

    /// The DER ECDSA P-256 SHA-256 signature, in unpadded base64url.
    public let signature: String

    init(_ payload: ApprovalPayload, signature: String) {
        taskID = payload.taskID
        nonce = payload.nonce
        reviewRequestedAt = payload.reviewRequestedAt
        self.signature = signature
    }
}

extension SignedApproval: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "SignedApproval(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
