import Foundation
import StrideKit

/// Opens the web sign-in and returns the URL the server sent the browser back
/// to, so that tests can replace the browser.
@MainActor
protocol WebAuthenticating {
    func authenticate(_ url: URL, callbackScheme: String) async throws(SignInError) -> URL
}
