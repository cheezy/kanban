import Foundation
import StrideKit

extension AppRouter {
    /// The app's one client, or the fixtures in a debug build that signs in
    /// through the stub, which has no server to ask and keeps nothing in the
    /// cache, with a review too large for a phone when asked
    /// (`StubLargeReview`).
    static func atLaunch(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        api: (any StrideAPI)? = StrideApp.api,
        live: LiveChannel? = StrideApp.live,
        cache: Cache? = StrideApp.cache,
        store: AuthStore? = StrideApp.authStore
    ) -> AppRouter {
        #if DEBUG
        if StubSignIn(arguments: arguments) != nil {
            return AppRouter(
                api: FixtureAPI(replacing: StubLargeReview.replacements(arguments: arguments)).client,
                approvals: StubApprovalSigning(arguments: arguments)
            )
        }
        #endif

        return AppRouter(api: api, live: live, cache: cache, approvals: approvals(store: store, api: api))
    }

    /// The device's signer, which has a new key made through the same sign-in
    /// the Sign in screen uses.
    private static func approvals(store: AuthStore?, api: (any StrideAPI)?) -> (any ApprovalSigning)? {
        guard let store, let api else { return nil }

        let services = SignInServices(
            store: store,
            api: api,
            keyMaker: SecureEnclaveKeyMaker(),
            device: .current()
        )
        return DeviceApprovalSigning(store: store, services: services)
    }
}
