#if DEBUG
import Foundation
import StrideKit

/// A browser that answers at once, as the server would. It records each page it
/// was asked to open.
@MainActor
final class StubWebAuthenticator: WebAuthenticating {
    enum Outcome {
        /// The person allows the device: the callback has a code and the state.
        case allow
        /// The person presses Cancel on the web page.
        case deny
        /// The person closes the browser window.
        case cancel
        /// A callback whose state is not the attempt's.
        case otherState
    }

    private let outcome: Outcome
    private(set) var opened: [URL] = []

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    func authenticate(_ url: URL, callbackScheme: String) async throws(SignInError) -> URL {
        opened.append(url)
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "state" }?.value ?? ""
        let callback = "\(callbackScheme):/oauth/callback"

        switch outcome {
        case .allow: return URL(string: "\(callback)?code=EXAMPLE&state=\(state)")!
        case .deny: return URL(string: "\(callback)?error=access_denied&state=\(state)")!
        case .otherState: return URL(string: "\(callback)?code=EXAMPLE&state=OTHER")!
        case .cancel: throw .cancelled
        }
    }
}
#endif
