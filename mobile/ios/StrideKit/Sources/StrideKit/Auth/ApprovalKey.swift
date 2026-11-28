import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// The device's P-256 approval key, made at sign-in. The server checks later
/// approvals against its public half, and `AuthStore` keeps it beside the token
/// pair, so signing out removes both. It remembers the biometric enrolment it
/// was made under, so `ApprovalSigner` can replace it after a change.
///
/// It prints as `ApprovalKey(redacted)`.
public struct ApprovalKey: Equatable, Sendable {
    /// What the token exchange sends: the 65-byte uncompressed point in base64url
    /// without padding, 87 characters.
    public let publicKey: String

    /// On a device, the Secure Enclave's encrypted handle to the private key,
    /// which only this device's enclave can use.
    let handle: Data

    /// The faces or fingers enrolled when the key was made.
    let biometry: BiometryState

    init(publicKey: P256.Signing.PublicKey, handle: Data, biometry: BiometryState) {
        self.init(
            publicKey: publicKey.x963Representation.base64URLEncodedString(),
            handle: handle,
            biometry: biometry
        )
    }

    init(publicKey: String, handle: Data, biometry: BiometryState) {
        self.publicKey = publicKey
        self.handle = handle
        self.biometry = biometry
    }

    /// Making the key asks for nothing. Each use will ask for Face ID, Touch ID or
    /// the passcode, and the key stops working if the passcode is removed. A new
    /// enrolment of faces or fingers may leave it working through the passcode,
    /// so the key keeps the enrolment it was made under (`biometry`) and
    /// `ApprovalSigner` replaces it when the enrolment now differs.
    static func make() throws(SignInError) -> ApprovalKey {
        #if targetEnvironment(simulator)
        // The simulator has no Secure Enclave and no passcode.
        let key = P256.Signing.PrivateKey()
        return ApprovalKey(publicKey: key.publicKey, handle: key.rawRepresentation, biometry: .current())
        #else
        var problem: NSError?
        if LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) == false,
           problem?.code == LAError.passcodeNotSet.rawValue {
            throw .passcodeNotSet
        }
        guard
            SecureEnclave.isAvailable,
            let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                [.privateKeyUsage, .biometryCurrentSet, .or, .devicePasscode],
                nil
            ),
            let key = try? SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        else { throw .failed }

        return ApprovalKey(publicKey: key.publicKey, handle: key.dataRepresentation, biometry: .current())
        #endif
    }

    #if DEBUG
    /// A software key, for previews and tests.
    public static func example() -> ApprovalKey {
        example(biometry: .none)
    }

    /// A software key made under `biometry`.
    static func example(biometry: BiometryState) -> ApprovalKey {
        let key = P256.Signing.PrivateKey()
        return ApprovalKey(publicKey: key.publicKey, handle: key.rawRepresentation, biometry: biometry)
    }
    #endif
}

extension ApprovalKey: Codable {
    private enum CodingKeys: String, CodingKey {
        case publicKey = "public_key"
        case handle
        case biometry
    }
}

extension ApprovalKey: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "ApprovalKey(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
