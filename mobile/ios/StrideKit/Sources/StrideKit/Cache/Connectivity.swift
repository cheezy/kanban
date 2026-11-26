import Foundation
import Network
import os

/// Whether the device can reach the network, for the offline banner and for
/// disabling the actions that need a connection.
public enum ConnectivityState: Sendable, Equatable {
    case online
    case offline
}

/// Reports the device's connectivity as it changes.
public struct Connectivity: Sendable {
    /// Starts reporting whether the device is online and returns what stops it.
    typealias Source = @Sendable (_ report: @escaping @Sendable (Bool) -> Void) -> @Sendable () -> Void

    private let source: Source

    init(source: @escaping Source) {
        self.source = source
    }

    /// The system's path monitor.
    public static var system: Connectivity {
        Connectivity { report in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in report(path.status == .satisfied) }
            monitor.start(queue: DispatchQueue(label: "StrideKit.Connectivity"))
            return { monitor.cancel() }
        }
    }

    /// The state now, then each change, until the caller stops listening. Only
    /// the newest state waits for a slow reader.
    public func states() -> AsyncStream<ConnectivityState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let last = OSAllocatedUnfairLock<ConnectivityState?>(initialState: nil)
            let stop = source { isOnline in
                let state: ConnectivityState = isOnline ? .online : .offline
                last.withLock { previous in
                    guard previous != state else { return }

                    previous = state
                    continuation.yield(state)
                }
            }
            continuation.onTermination = { _ in stop() }
        }
    }
}
