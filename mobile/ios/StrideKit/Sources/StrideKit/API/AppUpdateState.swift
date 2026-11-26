import Foundation
import Observation

/// Whether the server still accepts this version of the app. Once it has refused
/// it, the app stays refused until it is updated and started again.
@MainActor
@Observable
public final class AppUpdateState {
    /// Where to get the update, or nil while this version is accepted.
    public private(set) var storeURL: URL?

    public init(storeURL: URL? = nil) {
        self.storeURL = storeURL
    }

    func requireUpdate(from storeURL: URL) {
        self.storeURL = storeURL
    }
}
