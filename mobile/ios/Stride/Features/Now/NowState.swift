/// What the Now screen shows below its filters.
enum NowState: Equatable, Sendable {
    /// The first answer is still on its way.
    case loading
    /// Offline, with nothing saved on the device to show.
    case nothingSaved
    /// Nothing is waiting on the person.
    case empty
    case cards
}
