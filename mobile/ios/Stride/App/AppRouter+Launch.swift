import Foundation
import StrideKit

extension AppRouter {
    /// The app's one client, or the fixtures in a debug build that signs in
    /// through the stub, which has no server to ask.
    static func atLaunch(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        api: (any StrideAPI)? = StrideApp.api,
        live: LiveChannel? = StrideApp.live
    ) -> AppRouter {
        #if DEBUG
        if StubSignIn(arguments: arguments) != nil { return AppRouter(api: FixtureAPI().client) }
        #endif

        return AppRouter(api: api, live: live)
    }
}
