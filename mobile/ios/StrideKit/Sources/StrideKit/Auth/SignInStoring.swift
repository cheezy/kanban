/// What the Sign in screen needs from `AuthStore`, so that tests can replace it.
public protocol SignInStoring: Sendable {
    /// Whether the device is signed in: the state now, then each change.
    func signedIn() async throws(AuthStoreError) -> AsyncStream<Bool>

    /// Stores the pair and the approval key of a new sign-in.
    func save(_ pair: TokenPair, approvalKey: ApprovalKey) async throws(AuthStoreError)
}

extension AuthStore: SignInStoring {}
