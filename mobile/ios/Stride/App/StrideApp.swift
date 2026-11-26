import StrideKit
import SwiftUI

@main
struct StrideApp: App {
    static let appGroup = AppGroup(bundle: .main)
    static let authStore = appGroup.flatMap { AuthStore(group: $0) }
    static let update = AppUpdateState.atLaunch()

    /// The one client of the app. Two would refresh the same token twice, and the
    /// server revokes the device for that.
    static let api: (any StrideAPI)? = {
        guard let authStore, let version = AppVersion(bundle: .main) else { return nil }

        return APIClient.make(version: version, store: authStore, update: update)
    }()

    var body: some Scene {
        WindowGroup {
            RootView(update: Self.update)
                .task {
                    // After a failure every read stays nil, and the next launch or
                    // sign-in tries again.
                    try? await Self.authStore?.clearItemsFromPreviousInstall()
                }
        }
    }
}
