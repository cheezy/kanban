/// Makes the approval key a sign-in sends, so that tests can replace it.
public protocol ApprovalKeyMaking: Sendable {
    func makeKey() async throws(SignInError) -> ApprovalKey
}

/// Makes the key in the Secure Enclave, or in software on the simulator.
public struct SecureEnclaveKeyMaker: ApprovalKeyMaking {
    public init() {}

    /// Off the main actor, since the enclave can take a moment.
    @concurrent
    public func makeKey() async throws(SignInError) -> ApprovalKey {
        try ApprovalKey.make()
    }
}
