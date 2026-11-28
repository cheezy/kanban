import Foundation
import StrideKit

/// The project checks' result, for "Tests and checks".
enum ReviewChecks: Hashable, Sendable {
    case allPassed
    case notMet(Int)
    /// The reviewer reported no checks.
    case notReported

    init(_ checks: Components.Schemas.ReviewProjectChecks) {
        if checks.notMet > 0 {
            self = .notMet(checks.notMet)
        } else if checks.met > 0 {
            self = .allPassed
        } else {
            self = .notReported
        }
    }
}
