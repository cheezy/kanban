import Foundation
import StrideKit

/// Has a new approval key made and registered through a new sign-in, which
/// `ApprovalSigner` asks for when the key is missing, the enrolment changed or
/// the Secure Enclave refused it: only the token exchange carries a public key.
@MainActor
final class SignInKeyRegistrar: ApprovalKeyRegistering {
    private let services: SignInServices
    private let web: any WebAuthenticating

    init(services: SignInServices, web: any WebAuthenticating) {
        self.services = services
        self.web = web
    }

    /// False when the person closes the browser window.
    func registerNewKey() async throws(SignInError) -> Bool {
        do {
            try await OAuthSignIn.run(services, web: web)
            return true
        } catch {
            if error == .cancelled { return false }
            throw error
        }
    }
}
