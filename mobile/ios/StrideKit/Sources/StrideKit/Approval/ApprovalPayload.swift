import Foundation

/// What an approval signs: the server's one-time challenge with the task, its
/// `review_requested_at` and the decision bound in (design section 7.5).
///
/// The signing string is five lines joined by a line feed, in UTF-8 and with no
/// line feed at the end:
///
///     stride-approval-v1
///     <nonce>
///     <task id>
///     <review_requested_at, or nothing when the task has none>
///     approve
///
/// `Kanban.Reviews.ApprovalSignature` builds the same string on the server.
///
/// It prints as `ApprovalPayload(redacted)`, since the nonce is a credential
/// until it is used.
struct ApprovalPayload: Equatable, Sendable {
    static let version = "stride-approval-v1"
    static let decision = "approve"

    let nonce: String
    let taskID: Int
    let reviewRequestedAt: String

    /// Throws `invalidChallenge` for a value that could change the meaning of
    /// the lines: an empty nonce, a character outside unpadded base64url in it,
    /// a task id that is not positive, or a line break in `reviewRequestedAt`.
    init(nonce: String, taskID: Int, reviewRequestedAt: String) throws(ApprovalSignerError) {
        guard
            nonce.isEmpty == false,
            nonce.unicodeScalars.allSatisfy(Self.nonceCharacters.contains),
            taskID > 0,
            reviewRequestedAt.unicodeScalars.allSatisfy({ CharacterSet.newlines.contains($0) == false })
        else { throw .invalidChallenge }

        self.nonce = nonce
        self.taskID = taskID
        self.reviewRequestedAt = reviewRequestedAt
    }

    /// The challenge's own values, unchanged: `review_requested_at` is signed as
    /// the server spelled it, never parsed and written again.
    init(_ challenge: Components.Schemas.ApprovalChallenge) throws(ApprovalSignerError) {
        guard
            challenge.signingVersion.rawValue == Self.version,
            challenge.decision.rawValue == Self.decision
        else { throw .invalidChallenge }

        try self.init(
            nonce: challenge.nonce,
            taskID: challenge.taskId,
            reviewRequestedAt: challenge.reviewRequestedAt
        )
    }

    var signingString: String {
        [Self.version, nonce, String(taskID), reviewRequestedAt, Self.decision].joined(separator: "\n")
    }

    /// The bytes the key signs.
    var message: Data { Data(signingString.utf8) }

    private static let nonceCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )
}

extension ApprovalPayload: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "ApprovalPayload(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: []) }
}
