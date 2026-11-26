import Foundation
import StrideKit

/// Which screen fills the window.
enum RootScreen: Equatable {
    case updateRequired(URL)
    /// The Sign in screen, which also shows the locked panel.
    case signIn
    /// The background alone, while the Keychain or the server has not answered.
    case waiting
    case shell

    /// An outdated app shows Update required whatever else holds. Signed out
    /// always shows Sign in, and the shell shows only once the server has said
    /// the plan includes the app or could not say.
    init(storeURL: URL?, phase: SignInPhase) {
        if let storeURL {
            self = .updateRequired(storeURL)
            return
        }

        switch phase {
        case .signedOut, .signingIn, .locked: self = .signIn
        case .starting, .signedIn(.checking): self = .waiting
        case .signedIn(.unlocked), .signedIn(.unknown): self = .shell
        case .signedIn(.locked): self = .signIn
        }
    }
}
