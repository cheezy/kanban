import Foundation

/// Why an approval did not go through, which the review screen says above its
/// buttons. Approve stays available, so the person can try again.
enum ApproveProblem: Hashable, Sendable {
    /// The signed challenge ran out or was used before it reached Stride.
    case expired
    /// Stride did not accept this device's signature.
    case refused
    /// The person's access or plan changed.
    case notAllowed
    /// The device has no passcode, which an approval key needs.
    case passcodeNotSet
    case failed

    var text: LocalizedStringResource {
        switch self {
        case .expired: .reviewApproveExpired
        case .refused: .reviewApproveRefused
        case .notAllowed: .nowNotAllowed
        case .passcodeNotSet: .signInPasscodeRequired
        case .failed: .nowActionFailed
        }
    }
}
