import AuthenticationServices
import StrideKit
import SwiftUI

/// The system's secure browser window. It shares cookies with Safari, so a
/// company sign-in or a two-step check the person passed on the web carries over.
@MainActor
struct SystemWebAuthenticator: WebAuthenticating {
    let session: WebAuthenticationSession

    func authenticate(_ url: URL, callbackScheme: String) async throws(SignInError) -> URL {
        do {
            return try await session.authenticate(
                using: url,
                callbackURLScheme: callbackScheme,
                preferredBrowserSession: .shared
            )
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            throw .cancelled
        } catch {
            throw .failed
        }
    }
}
