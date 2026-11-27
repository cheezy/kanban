import Foundation
import os
import Testing

@testable import StrideKit

/// Answers `LiveChannel`'s token requests, opens a `FakeLiveConnection` for each
/// connect, and records each pause and sign-out. Its answers come in order, then
/// a fresh token for every request.
final class FakeLiveServer: Sendable {
    private struct Record {
        var answers: [SocketTokenAnswer]
        var asked = 0
        var connections: [FakeLiveConnection] = []
        var pauses: [Duration] = []
        var signOuts = 0
    }

    private let record: OSAllocatedUnfairLock<Record>

    init(answers: [SocketTokenAnswer] = []) {
        record = OSAllocatedUnfairLock(initialState: Record(answers: answers))
    }

    var asked: Int { record.withLock { $0.asked } }
    var connections: [FakeLiveConnection] { record.withLock { $0.connections } }
    var pauses: [Duration] { record.withLock { $0.pauses } }
    var signOuts: Int { record.withLock { $0.signOuts } }

    func channel() -> LiveChannel {
        LiveChannel(
            socketToken: { self.answer() },
            connect: { self.open($0) },
            pause: { self.paused($0) },
            signOut: { self.signedOut() }
        )
    }

    /// The `number`th connection, once it has been opened.
    func connection(_ number: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws -> FakeLiveConnection {
        await eventually("connection \(number) opens", sourceLocation: sourceLocation) { connections.count >= number }
        return try #require(connections.dropFirst(number - 1).first, sourceLocation: sourceLocation)
    }

    private func answer() -> SocketTokenAnswer {
        record.withLock { record in
            record.asked += 1
            return record.answers.isEmpty ? .token("EXAMPLE-socket-\(record.asked)") : record.answers.removeFirst()
        }
    }

    private func open(_ token: String) -> any LiveConnection {
        let connection = FakeLiveConnection(token: token)
        record.withLock { $0.connections.append(connection) }
        return connection
    }

    private func paused(_ delay: Duration) {
        record.withLock { $0.pauses.append(delay) }
    }

    private func signedOut() {
        record.withLock { $0.signOuts += 1 }
    }
}

/// Waits until `condition` holds, for up to five seconds, and records an issue
/// if it never does.
func eventually(
    _ what: String,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () async -> Bool
) async {
    for _ in 0..<500 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Never happened: \(what)", sourceLocation: sourceLocation)
}
