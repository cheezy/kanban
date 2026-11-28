@testable import StrideKit

/// A connection that never opens, for a channel that must not connect.
final class IdleConnection: LiveConnection {
    let events = AsyncStream<LiveConnectionEvent> { $0.finish() }

    func join(_ topic: LiveTopic) {}

    func leave(_ topic: LiveTopic) {}

    func close() {}
}
