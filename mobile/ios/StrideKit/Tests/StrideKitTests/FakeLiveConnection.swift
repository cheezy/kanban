import Foundation
import os

@testable import StrideKit

/// A connection the test drives: it records what `LiveChannel` asked of it, and
/// reports the events the test sends.
final class FakeLiveConnection: LiveConnection, Sendable {
    enum Action: Sendable, Hashable {
        case join(LiveTopic)
        case leave(LiveTopic)
        case close
    }

    let token: String
    let events: AsyncStream<LiveConnectionEvent>
    private let sink: AsyncStream<LiveConnectionEvent>.Continuation
    private let recorded = OSAllocatedUnfairLock<[Action]>(initialState: [])

    init(token: String) {
        self.token = token
        (events, sink) = AsyncStream.makeStream(of: LiveConnectionEvent.self)
    }

    var actions: [Action] { recorded.withLock { $0 } }

    func join(_ topic: LiveTopic) { record(.join(topic)) }

    func leave(_ topic: LiveTopic) { record(.leave(topic)) }

    func close() {
        record(.close)
        sink.finish()
    }

    func send(_ event: LiveConnectionEvent) { sink.yield(event) }

    /// The server pushes `body` on the topic's own event.
    func push(_ topic: LiveTopic, _ body: Data) { send(.pushed(topic, event: topic.event, payload: body)) }

    /// The socket closes or its connect is refused, without being asked to.
    func drop() { sink.finish() }

    private func record(_ action: Action) {
        recorded.withLock { $0.append(action) }
    }
}
