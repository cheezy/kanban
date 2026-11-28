import Foundation

/// A review the server refused to let this device approve, named by when it
/// was requested: a resubmission is a new review, which the server may let
/// the device approve again.
struct RefusedReview: Equatable, Sendable {
    let requestedAt: Date?
}
