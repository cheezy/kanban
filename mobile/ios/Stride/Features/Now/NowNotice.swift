import Foundation

/// What the Now screen says after a card's action: that it worked, or why
/// it did not. The reply sheet says the same about a reply.
enum NowNotice: Hashable, Sendable {
    case movedToBacklog
    case replySent
    /// The task moved or went away since the list was fetched, so the list
    /// is fetched again to show where things stand.
    case taskMoved
    /// The person can no longer change the task: their access or plan changed.
    case notAllowed
    case failed

    var text: LocalizedStringResource {
        switch self {
        case .movedToBacklog: .nowMovedToBacklog
        case .replySent: .nowReplySent
        case .taskMoved: .nowTaskMoved
        case .notAllowed: .nowNotAllowed
        case .failed: .nowActionFailed
        }
    }

    /// A notice that something went wrong, rather than a confirmation.
    var isProblem: Bool {
        switch self {
        case .movedToBacklog, .replySent: false
        case .taskMoved, .notAllowed, .failed: true
        }
    }
}
