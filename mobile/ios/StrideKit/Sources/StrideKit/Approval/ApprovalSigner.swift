import Foundation

/// Signs an approval with the device's approval key (design sections 6.6 and
/// 7.5): the server's one-time challenge, with the task, its
/// `review_requested_at` and the decision bound in, after Face ID, Touch ID or
/// the passcode.
///
/// The key was made at sign-in, in the Secure Enclave, and its public half sent
/// with the token exchange. When there is no key, or the enrolled faces or
/// fingers have changed since it was made, or the enclave refuses it, the signer
/// has a new one made and registered through `ApprovalKeyRegistering` (a new
/// sign-in) and asks for a new challenge before it signs, since the old one
/// belongs to the old key's device. One approval asks for at most one new
/// sign-in: a new key the enclave refuses is `ApprovalSignerError.keyUnusable`.
///
/// Nothing here logs: the payload and the result print as redacted.
public struct ApprovalSigner: Sendable {
    public enum Outcome: Equatable, Sendable {
        case signed(SignedApproval)

        /// The person closed the Face ID, Touch ID or passcode prompt, or stopped
        /// the sign-in a new key needs. Nothing was signed, and nothing is wrong.
        case cancelled
    }

    private let store: AuthStore
    private let registrar: any ApprovalKeyRegistering
    private let unlocker: any ApprovalKeyUnlocking

    public init(store: AuthStore, registrar: any ApprovalKeyRegistering) {
        self.init(store: store, registrar: registrar, unlocker: SecureEnclaveUnlocker())
    }

    init(store: AuthStore, registrar: any ApprovalKeyRegistering, unlocker: any ApprovalKeyUnlocking) {
        self.store = store
        self.registrar = registrar
        self.unlocker = unlocker
    }

    /// Signs the challenge `challenge` fetches, after asking with `reason`, which
    /// the app gives as "Approve W2701".
    ///
    /// `challenge` is called once, or twice when the key had to be replaced
    /// after the first one was fetched, and an error it throws is rethrown
    /// unchanged. Every other error is an `ApprovalSignerError`.
    public func sign(
        reason: String,
        challenge: @Sendable () async throws -> Components.Schemas.ApprovalChallenge
    ) async throws -> Outcome {
        guard let (key, isNew) = try await currentKey() else { return .cancelled }

        if let outcome = try await attempt(with: key, reason: reason, challenge: challenge) {
            return outcome
        }

        // A key this call just had made is not replaced again: one approval
        // never opens a second sign-in.
        if isNew { throw ApprovalSignerError.keyUnusable }

        guard let replaced = try await replaceKey() else { return .cancelled }

        guard let outcome = try await attempt(with: replaced, reason: reason, challenge: challenge) else {
            throw ApprovalSignerError.keyUnusable
        }
        return outcome
    }

    /// The stored key while it matches the enrolment now, else a new one, with
    /// whether it is new; nil when the person stops the sign-in that would make
    /// it.
    private func currentKey() async throws(ApprovalSignerError) -> (key: ApprovalKey, isNew: Bool)? {
        if let key = try await storedKey(), await unlocker.biometry().changed(since: key.biometry) == false {
            return (key, false)
        }
        guard let key = try await replaceKey() else { return nil }
        return (key, true)
    }

    /// Signs one fetched challenge. Nil when the enclave refused the key.
    private func attempt(
        with key: ApprovalKey,
        reason: String,
        challenge: @Sendable () async throws -> Components.Schemas.ApprovalChallenge
    ) async throws -> Outcome? {
        let payload = try ApprovalPayload(try await challenge())

        do {
            let signature = try await unlocker.sign(payload.message, with: key, reason: reason)
            return .signed(SignedApproval(payload, signature: signature.base64URLEncodedString()))
        } catch {
            switch error {
            case .cancelled: return .cancelled
            case .keyUnusable: return nil
            case .passcodeNotSet: throw ApprovalSignerError.passcodeNotSet
            case .failed: throw ApprovalSignerError.failed
            }
        }
    }

    /// Has a new key made and registered, then reads it back from the store.
    private func replaceKey() async throws(ApprovalSignerError) -> ApprovalKey? {
        do {
            guard try await registrar.registerNewKey() else { return nil }
        } catch .cancelled {
            return nil
        } catch {
            throw .signIn(error)
        }

        guard let key = try await storedKey() else { throw .keyUnavailable }
        return key
    }

    private func storedKey() async throws(ApprovalSignerError) -> ApprovalKey? {
        do {
            return try await store.approvalKey()
        } catch {
            throw .keyUnavailable
        }
    }
}
