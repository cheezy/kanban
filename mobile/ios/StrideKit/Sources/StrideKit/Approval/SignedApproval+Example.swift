#if DEBUG
extension SignedApproval {
    /// An approval of `challenge` with a made-up signature, for previews, the
    /// UI tests' stub signer and tests. The server would refuse it.
    public static func example(for challenge: Components.Schemas.ApprovalChallenge) throws -> SignedApproval {
        SignedApproval(try ApprovalPayload(challenge), signature: "EXAMPLE-signature")
    }
}
#endif
