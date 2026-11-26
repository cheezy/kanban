import Foundation
import OpenAPIRuntime

/// Why a sign-in did not finish. No case holds a code, a token or a response.
public enum SignInError: Error, Equatable, Sendable {
    /// The person closed the browser window or pressed Cancel on the web.
    case cancelled

    /// The server could not be reached.
    case network

    /// The device has no passcode, which the approval key needs.
    case passcodeNotSet

    /// Anything else: a callback this attempt did not ask for, or a refusal. Each
    /// needs a new attempt, because the server burns a code it refuses.
    case failed

    /// What `error`, thrown by a call through `StrideAPI`, means for a sign-in.
    public init(classifying error: any Error) {
        switch error {
        case let error as SignInError:
            self = error
        case is CancellationError:
            self = .cancelled
        case let error as ClientError:
            self.init(classifying: error.underlyingError)
        case let error as URLError:
            self = error.code == .cancelled ? .cancelled : .network
        default:
            self = .failed
        }
    }
}
