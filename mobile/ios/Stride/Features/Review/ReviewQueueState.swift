import Foundation

/// What the Review queue shows below its header.
enum ReviewQueueState: Equatable, Sendable {
    /// The first answer is still on its way.
    case loading
    /// Offline, with nothing saved on the device to show.
    case nothingSaved
    /// No review waits on the person.
    case empty
    case rows
}
