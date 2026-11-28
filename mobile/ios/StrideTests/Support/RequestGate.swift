/// Holds a fixture request until the test opens it, and says when one is
/// held, so a test can order a race without a sleep.
final class RequestGate: Sendable {
    private let held = AsyncStream<Void>.makeStream()
    private let opened = AsyncStream<Void>.makeStream()

    /// Called by the held request: says it arrived, then waits.
    func wait() async {
        held.continuation.yield()
        for await _ in opened.stream { break }
    }

    func untilHeld() async {
        for await _ in held.stream { break }
    }

    func open() {
        opened.continuation.yield()
    }
}
