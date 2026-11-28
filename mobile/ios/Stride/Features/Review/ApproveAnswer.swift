import StrideKit

/// What one tap of Approve came to.
enum ApproveAnswer: Sendable {
    /// Approved: the tasks the review held up, which can start now.
    case approved(holdsUp: [String])
    /// The person closed the Face ID, Touch ID or passcode prompt, or the
    /// sign-in a new key needed. Nothing was sent.
    case cancelled
    /// 409: decided by someone else, resubmitted or edited since it loaded.
    case conflict(Components.Schemas.ReviewConflict)
    /// 404: no longer the person's to decide.
    case gone
    /// 422 too_large_for_phone: the review changed since it loaded, and is
    /// loaded again to show where to approve it.
    case tooLarge
    case problem(ApproveProblem)
}
