import StrideKit
import SwiftUI

@main
struct StrideApp: App {
    static let appGroup = AppGroup(bundle: .main)
    static let authStore = appGroup.flatMap { AuthStore(group: $0) }

    var body: some Scene {
        WindowGroup {
            RootView()
                .task {
                    // After a failure every read stays nil, and the next launch or
                    // sign-in tries again.
                    try? await Self.authStore?.clearItemsFromPreviousInstall()
                }
        }
    }
}
