@testable import StrideKit

/// Reads one `LiveChannel` stream as a listening screen would, until stopped,
/// and keeps every update it read in `received`.
final class LiveListener: Sendable {
    let received: AsyncStream<LiveUpdate>
    private let task: Task<Void, Never>

    init(_ updates: AsyncStream<LiveUpdate>) {
        let (received, sink) = AsyncStream.makeStream(of: LiveUpdate.self)
        self.received = received
        task = Task {
            for await update in updates { sink.yield(update) }
            sink.finish()
        }
    }

    func stop() { task.cancel() }
}
