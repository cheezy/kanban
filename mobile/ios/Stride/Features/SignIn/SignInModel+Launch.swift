import Foundation
import StrideKit

extension SignInModel {
    /// Starts a debug build with a stub browser, the fixtures and a store kept in
    /// memory, so the screen can be seen and tested without a server. Follow it
    /// with `allow`, `cancel`, `locked` or `offline`.
    nonisolated static let stubSignInArgument = "-StrideStubSignIn"

    static func atLaunch(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        store: AuthStore? = StrideApp.authStore,
        api: (any StrideAPI)? = StrideApp.api
    ) -> SignInModel {
        #if DEBUG
        if let stub = StubSignIn(arguments: arguments) { return stub.model() }
        #endif

        guard let store, let api else { return SignInModel(services: nil) }

        return SignInModel(
            services: SignInServices(
                store: store,
                api: api,
                keyMaker: SecureEnclaveKeyMaker(),
                device: .current()
            )
        )
    }
}
