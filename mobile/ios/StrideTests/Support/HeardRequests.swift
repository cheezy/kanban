import Foundation
import os

@testable import StrideKit

/// What a fixture server heard: each request in order, with its idempotency
/// key and body, including one lost on the way. Decision tests compare keys
/// and bodies through it without printing them.
final class HeardRequests: Sendable {
    private struct Request: Sendable {
        let operation: String
        let key: String?
        let body: Data?
    }

    private let state = OSAllocatedUnfairLock(initialState: [Request]())

    var operations: [String] { state.withLock { $0.map(\.operation) } }

    /// The idempotency key of each request of the operation, in order.
    func keys(of operation: String) -> [String?] {
        state.withLock { $0.filter { $0.operation == operation }.map(\.key) }
    }

    /// The body of each request of the operation, in order.
    func bodies(of operation: String) -> [Data?] {
        state.withLock { $0.filter { $0.operation == operation }.map(\.body) }
    }

    /// A fixture server that tells this what it hears.
    func fixtures(
        replacing replacements: [String: Data] = [:],
        statuses: [String: Int] = [:],
        isOffline: @escaping @Sendable () -> Bool = { false },
        onSend: @escaping @Sendable (String, Data?) -> Void = { _, _ in },
        status: @escaping @Sendable (String) -> Int? = { _ in nil },
        hold: @escaping @Sendable (String) async -> Void = { _ in }
    ) -> FixtureAPI {
        FixtureAPI(
            replacing: replacements,
            statuses: statuses,
            isOffline: isOffline,
            onSend: onSend,
            status: status,
            onRequest: { id, headers, body in
                self.hear(id, key: headers.first { $0.name.canonicalName == "idempotency-key" }?.value, body: body)
            },
            hold: hold
        )
    }

    private func hear(_ operationID: String, key: String?, body: Data?) {
        state.withLock { $0.append(Request(operation: operationID, key: key, body: body)) }
    }
}
