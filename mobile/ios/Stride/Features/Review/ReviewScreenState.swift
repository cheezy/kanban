import Foundation

/// What the review screen shows.
enum ReviewScreenState: Equatable, Sendable {
    /// The first answer is still on its way.
    case loading
    /// Offline, with nothing saved on the device to show.
    case nothingSaved
    /// The review no longer waits on the person.
    case unavailable
    case review
}
