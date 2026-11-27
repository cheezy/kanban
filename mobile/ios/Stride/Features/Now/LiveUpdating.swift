import StrideKit

/// The live updates a view model reads, so tests can send their own.
protocol LiveUpdating: Sendable {
    func updates(of topic: LiveTopic) async -> AsyncStream<LiveUpdate>
}

extension LiveChannel: LiveUpdating {}
