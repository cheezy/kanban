import Foundation

/// Why a request for changes did not go through, which the sheet says above
/// its field. The notes stay, so the person can send them again.
enum RequestChangesProblem: Hashable, Sendable {
    /// The person's access or plan changed.
    case notAllowed
    /// 422: Stride refused the notes, as blank or holding a character it
    /// cannot keep.
    case refused
    case failed

    var text: LocalizedStringResource {
        switch self {
        case .notAllowed: .nowNotAllowed
        case .refused: .reviewChangesRefused
        case .failed: .nowActionFailed
        }
    }
}
