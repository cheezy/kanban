import CryptoKit
import CryptoTokenKit
import Foundation
import LocalAuthentication

/// Why the key did not sign.
enum ApprovalUnlockError: Error, Equatable, Sendable {
    /// The person, the system or the app closed the prompt.
    case cancelled

    /// The device has no passcode.
    case passcodeNotSet

    /// The Secure Enclave would not use the key: it was invalidated or is not
    /// this device's.
    case keyUnusable

    /// The prompt could not be shown or failed for another reason.
    case failed

    /// What an error from `LAContext.evaluatePolicy`, or the task's
    /// cancellation, means here.
    init(_ error: any Error) {
        self = Self.answer(to: error) ?? .failed
    }

    /// What an error opening the key in the Secure Enclave or signing with it
    /// means here. The enclave can show a passcode sheet of its own when the
    /// unlocked context does not satisfy the key, so closing that is a cancel
    /// too, never a reason to replace the key. That sheet's cancel may arrive
    /// from CryptoTokenKit rather than LocalAuthentication, and an unlock the
    /// enclave no longer accepts (`invalidContext`) says nothing about the key,
    /// so only another error means the key itself is unusable.
    init(keyError error: any Error) {
        self = Self.answer(to: error) ?? Self.keyAnswer(to: error)
    }

    private static func keyAnswer(to error: any Error) -> ApprovalUnlockError {
        if (error as? TKError)?.code == .canceledByUser { return .cancelled }
        if (error as? LAError)?.code == .invalidContext { return .failed }
        return .keyUnusable
    }

    /// A cancel or a missing passcode, else nil.
    private static func answer(to error: any Error) -> ApprovalUnlockError? {
        if error is CancellationError { return .cancelled }

        switch (error as? LAError)?.code {
        case .userCancel, .systemCancel, .appCancel, .userFallback:
            return .cancelled
        case .passcodeNotSet:
            return .passcodeNotSet
        default:
            return nil
        }
    }
}

/// Unlocks the approval key and signs with it, so that tests can replace the
/// system prompt.
protocol ApprovalKeyUnlocking: Sendable {
    /// The enrolment now. Asks for nothing.
    func biometry() async -> BiometryState

    /// Asks for Face ID, Touch ID or the passcode with `reason` as the prompt's
    /// text, then signs `message` with `key`. Returns the DER signature.
    func sign(_ message: Data, with key: ApprovalKey, reason: String) async throws(ApprovalUnlockError) -> Data
}

/// Signs in the Secure Enclave after the system prompt, or in software on the
/// simulator, which has no Secure Enclave and no passcode.
struct SecureEnclaveUnlocker: ApprovalKeyUnlocking {
    @concurrent
    func biometry() async -> BiometryState {
        BiometryState.current()
    }

    /// Off the main actor, since the prompt and the enclave take time. The
    /// context the person unlocked is handed to the key, so the key's own check
    /// (biometrics of the current enrolment, or the passcode) uses that unlock
    /// and asks no second time.
    @concurrent
    func sign(_ message: Data, with key: ApprovalKey, reason: String) async throws(ApprovalUnlockError) -> Data {
        #if targetEnvironment(simulator)
        guard let privateKey = try? P256.Signing.PrivateKey(rawRepresentation: key.handle) else {
            throw .keyUnusable
        }
        guard let signature = try? privateKey.signature(for: message) else { throw .failed }

        return signature.derRepresentation
        #else
        let context = LAContext()
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            throw ApprovalUnlockError(error)
        }

        do {
            let privateKey = try SecureEnclave.P256.Signing.PrivateKey(
                dataRepresentation: key.handle,
                authenticationContext: context
            )
            return try privateKey.signature(for: message).derRepresentation
        } catch {
            throw ApprovalUnlockError(keyError: error)
        }
        #endif
    }
}
