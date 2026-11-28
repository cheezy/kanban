/// Makes a new approval key and registers its public half with the server.
///
/// The only request that carries a public key is the token exchange at the end
/// of a sign-in (`POST /oauth/token`, `approval_public_key`), so in the app this
/// is a new sign-in, as design section 9.3 says for a changed enrolment. It
/// keeps the key with the new pair through `AuthStore.save(_:approvalKey:)`.
public protocol ApprovalKeyRegistering: Sendable {
    /// Returns false when the person stops the sign-in.
    func registerNewKey() async throws(SignInError) -> Bool
}
