import Foundation
import StrideKit

/// The steps of one web sign-in, which the Sign in screen and a new approval
/// key share: make the key, open the web's authorize page, trade the code once
/// and keep the pair with the key.
enum OAuthSignIn {
    @MainActor
    static func run(_ services: SignInServices, web: any WebAuthenticating) async throws(SignInError) {
        // Before the browser opens: the code lives 60 seconds, and a device
        // that cannot hold a key should not go through the web first.
        let key = try await services.keyMaker.makeKey()
        let attempt = OAuthAttempt()
        let callback = try await web.authenticate(
            attempt.authorizeURL(for: services.device),
            callbackScheme: OAuthFlow.callbackScheme
        )
        let code = try attempt.code(from: callback)
        let pair = try await OAuthFlow.exchange(
            code,
            of: attempt,
            device: services.device,
            approvalPublicKey: key.publicKey,
            using: services.api
        )
        do {
            try await services.store.save(pair, approvalKey: key)
        } catch {
            throw .failed
        }
    }
}
