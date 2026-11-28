import Foundation
import LocalAuthentication

/// Which faces or fingers are enrolled, as far as the system says. The approval
/// key keeps the state from when it was made, so a later change can be noticed
/// before anyone is asked to approve (design section 9.3).
///
/// The state is an opaque hash the system gives, and says nothing about the person.
enum BiometryState: Codable, Equatable, Sendable {
    /// Face ID or Touch ID is set up, with this enrolment.
    case enrolled(Data)

    /// The device has biometrics, but nothing is enrolled.
    case none

    /// The state could not be read: the device has no biometrics, the person
    /// turned Face ID off for the app, or biometrics are locked out for now.
    case unknown

    /// The state now. Asks the person for nothing.
    static func current() -> BiometryState {
        let context = LAContext()
        var problem: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &problem) else {
            return BiometryState(unavailable: problem?.code)
        }

        return BiometryState(hash: domainState(of: context))
    }

    /// The state when the biometric policy could be evaluated: the hash, if the
    /// system gave one.
    init(hash: Data?) {
        self = hash.map(BiometryState.enrolled) ?? .unknown
    }

    /// The state when the biometric policy could not be evaluated, from the
    /// `LAError` code. Only "nothing enrolled" is a state; every other refusal
    /// leaves it unknown.
    init(unavailable code: Int?) {
        self = code == LAError.biometryNotEnrolled.rawValue ? .none : .unknown
    }

    /// Whether the enrolment is a different one from `earlier`. An unknown state
    /// on either side is never a change, so a lockout or a refused permission
    /// does not throw the key away.
    func changed(since earlier: BiometryState) -> Bool {
        self != .unknown && earlier != .unknown && self != earlier
    }

    private static func domainState(of context: LAContext) -> Data? {
        if #available(iOS 18, *) {
            return context.domainState.biometry.stateHash
        }
        return context.evaluatedPolicyDomainState
    }
}
