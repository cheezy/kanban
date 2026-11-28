/// What the file screen shows.
enum DiffScreenState: Equatable, Sendable {
    /// The first answer is still on its way.
    case loading
    /// Offline, with nothing saved on the device to show.
    case nothingSaved
    /// The file is no longer in the review.
    case gone
    case file
}
