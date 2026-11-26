import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// The device's P-256 approval key, made at sign-in. The server checks later
/// approvals against its public half, and `AuthStore` keeps it beside the token
/// pair, so signing out removes both.
///
/// It prints as `ApprovalKey(redacted)`.
public struct ApprovalKey: Equatable, Sendable {
    /// What the token exchange sends: the 65-byte uncompressed point in base64url
    /// without padding, 87 characters.
    public let publicKey: String

    /// On a device, the Secure Enclave's encrypted handle to the private key,
    /// which only this device's enclave can use.
    let handle: Data

    init(publicKey: P256.Signing.PublicKey, handle: Data) {
        self.publicKey = publicKey.x963Representation.base64URLEncodedString()
        self.handle = handle
    }

    /// Making the key asks for nothing. Each use will ask for Face ID, Touch ID or
    /// the passcode, and the key stops working if the passcode is removed or the
    /// enrolled faces or fingers change.
    static func make() throws(SignInError) -> ApprovalKey {
        #if targetEnvironment(simulator)
        // The simulator has no Secure Enclave and no passcode.
        let key = P256.Signing.PrivateKey()
        return ApprovalKey(publicKey: key.publicKey, handle: key.rawRepresentation)
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

        return ApprovalKey(publicKey: key.publicKey, handle: key.dataRepresentation)
        #endif
    }

    #if DEBUG
    /// A software key, for previews and tests.
    public static func example() -> ApprovalKey {
        let key = P256.Signing.PrivateKey()
        return ApprovalKey(publicKey: key.publicKey, handle: key.rawRepresentation)
    }
    #endif
}

extension ApprovalKey: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "ApprovalKey(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
