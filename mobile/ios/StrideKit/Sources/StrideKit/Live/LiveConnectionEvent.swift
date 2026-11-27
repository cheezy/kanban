import Foundation

/// What one `LiveConnection` reports.
enum LiveConnectionEvent: Sendable, Equatable {
    /// The socket is open, so channels can be joined.
    case opened

    /// The server accepted the join. Its full state follows as a push.
    case joined(LiveTopic)

    /// The server refused the join, with the reason it gave, such as
    /// `unauthorized` or `plan_required`, or nil when the join timed out.
    case refused(LiveTopic, reason: String?)

    /// The server closed one channel and left the socket open, as it does when
    /// the person loses access.
    case channelClosed(LiveTopic)

    /// A channel pushed an event.
    case pushed(LiveTopic, event: String, payload: Data)
}
