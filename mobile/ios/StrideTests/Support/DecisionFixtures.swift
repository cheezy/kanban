import Foundation
import os
import Testing

@testable import Stride
@testable import StrideKit

/// The shared `listMyDecisions` fixture, edited for one test. On the main
/// actor, like its suites, so an edit closure never crosses an isolation.
@MainActor
enum DecisionFixtures {
    typealias List = Components.Schemas.DecisionList

    /// The fixture's body with `edit` applied to its list of items.
    static func data(editingItems edit: (inout [[String: Any]]) -> Void = { _ in }) throws -> Data {
        let fixture = try FixtureAPI.fixture(named: Operations.ListMyDecisions.id)
        var root = try #require(try JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        var data = try #require(root["data"] as? [String: Any])
        var items = try #require(data["items"] as? [[String: Any]])
        edit(&items)
        data["items"] = items
        root["data"] = data
        return try JSONSerialization.data(withJSONObject: root)
    }

    /// A client that answers `listMyDecisions` with `data`.
    static func api(_ data: Data) -> some StrideAPI {
        FixtureAPI(replacing: [Operations.ListMyDecisions.id: data]).client
    }

    /// The list `data` decodes to, as the client reads it.
    static func list(_ data: Data) async throws -> List {
        try await api(data).listMyDecisions().ok.body.json.data
    }

    /// The fixture's cards, as the Now screen reads them.
    static func cards(editingItems edit: (inout [[String: Any]]) -> Void = { _ in }) async throws -> [NowCard] {
        try await list(data(editingItems: edit)).items.compactMap(NowCard.init)
    }
}

/// Live updates a test sends by hand.
struct ManualLive: LiveUpdating {
    let stream: AsyncStream<LiveUpdate>
    let continuation: AsyncStream<LiveUpdate>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func updates(of topic: LiveTopic) async -> AsyncStream<LiveUpdate> {
        stream
    }
}

/// A connection a test switches on and off.
final class ConnectivitySwitch: Sendable {
    private let report = ReporterBox()
    private let startsOnline: Bool

    init(online: Bool) {
        startsOnline = online
    }

    var connectivity: Connectivity {
        Connectivity { [report, startsOnline] send in
            report.set(send)
            send(startsOnline)
            return {}
        }
    }

    /// Whether the model has started listening, so a change reaches it.
    var isListening: Bool { report.get() != nil }

    func set(online: Bool) {
        report.get()?(online)
    }
}

/// Holds the switch's reporter behind a lock.
final class ReporterBox: Sendable {
    private let lock = OSAllocatedUnfairLock<(@Sendable (Bool) -> Void)?>(initialState: nil)

    func set(_ report: @escaping @Sendable (Bool) -> Void) {
        lock.withLock { $0 = report }
    }

    func get() -> (@Sendable (Bool) -> Void)? {
        lock.withLock { $0 }
    }
}

/// A directory that stands for the app group container, removed with the object.
final class TemporaryContainer {
    let url: URL

    init() throws {
        url = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Waits up to five seconds for `condition`.
@MainActor
func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<500 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
}
