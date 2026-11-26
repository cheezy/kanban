import StrideKit

/// Where the app is in signing in.
enum SignInPhase: Equatable {
    /// The Keychain has not said yet whether the device is signed in.
    case starting

    /// The Sign in screen, with the reason the last attempt failed, if it did.
    /// Pressing Cancel is no failure.
    case signedOut(SignInError?)

    /// The browser window is open, or its answer is being traded for tokens.
    case signingIn

    /// Signed in, but the person's plan does not include the app.
    case locked

    case signedIn(AppAccess)
}
