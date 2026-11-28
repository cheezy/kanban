/// Why an approval could not be signed. No case holds a nonce, a key or a
/// signature. A person who cancels is not an error: `ApprovalSigner` answers
/// `cancelled` instead.
public enum ApprovalSignerError: Error, Equatable, Sendable {
    /// The challenge held a value the signing string cannot carry.
    case invalidChallenge

    /// The device has no passcode any more, which removed the key with it. The
    /// person sets one and signs in again.
    case passcodeNotSet

    /// The Keychain could not read the key, or a new sign-in kept none.
    case keyUnavailable

    /// The Secure Enclave refused a key that a new sign-in had just made.
    case keyUnusable

    /// The sign-in that registers a new key failed.
    case signIn(SignInError)

    /// Anything else the system refused, such as a prompt it could not show.
    case failed
}
