import LocalAuthentication

/// What the person will use to approve: Face ID or Touch ID when it is set up,
/// and the passcode otherwise.
public enum ApprovalUnlock: Sendable {
    case faceID
    case touchID
    case passcode

    public static func current() -> ApprovalUnlock {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            return .passcode
        }

        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        default: return .passcode
        }
    }
}
