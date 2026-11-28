import Foundation
import StrideKit

/// A review that changed since the screen loaded it, from an HTTP 409.
enum ReviewConflictState: Hashable, Sendable {
    /// Someone decided it first: who, what they decided, and when.
    case alreadyDecided(by: String?, decision: ReviewDecision, at: Date?)
    /// The agent sent it for review again.
    case resubmitted

    /// The conflict the screen shows for the server's answer. An `edited`
    /// conflict, which only the approval challenge sends, reads as
    /// Resubmitted, since a reload settles it the same way.
    init(_ conflict: Components.Schemas.ReviewConflict) {
        let error = conflict.error.value1?.rawValue ?? conflict.error.value2
        switch error {
        case "already_decided":
            let review = conflict.review
            let status = review.reviewStatus.flatMap { $0.value1?.rawValue ?? $0.value2 }
            self = .alreadyDecided(
                by: review.reviewedBy,
                decision: ReviewDecision(apiValue: status),
                at: review.reviewedAt
            )
        default:
            self = .resubmitted
        }
    }
}
