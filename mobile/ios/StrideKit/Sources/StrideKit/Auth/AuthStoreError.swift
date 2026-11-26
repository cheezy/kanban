import Security

/// Why `AuthStore` could not do what it was asked. No case holds a token.
public enum AuthStoreError: Error, Equatable {
    /// The Keychain refused. It answers `errSecInteractionNotAllowed` until the
    /// device is first unlocked after a restart, which does not mean signed out.
    case keychain(OSStatus)

    /// The stored item is not a token pair this version can read, or the pair to
    /// store cannot be encoded.
    case invalidPair

    /// The pair to rotate or to clear is no longer the stored one, because another
    /// rotation, a sign-out or a sign-in came first.
    case superseded

    /// The marker of this install could not be written.
    case installNotMarked
}
