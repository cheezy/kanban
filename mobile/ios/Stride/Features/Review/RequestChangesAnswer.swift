import StrideKit

/// What one Send of Request changes came to.
enum RequestChangesAnswer: Sendable {
    /// The notes reached the agent's task, which waits for the changes.
    case sent
    /// 409: decided by someone else, resubmitted or edited since it loaded.
    case conflict(Components.Schemas.ReviewConflict)
    /// 404: no longer the person's to decide.
    case gone
    case problem(RequestChangesProblem)
}
