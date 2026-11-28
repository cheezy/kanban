import Foundation
import StrideKit

/// Signs with the device's approval key through `ApprovalSigner`, which has a
/// new key made through a new sign-in when it must.
@MainActor
struct DeviceApprovalSigning: ApprovalSigning {
    let store: AuthStore
    let services: SignInServices

    func sign(
        reason: String,
        web: any WebAuthenticating,
        challenge: @escaping @Sendable () async throws -> Components.Schemas.ApprovalChallenge
    ) async throws -> ApprovalSigner.Outcome {
        let signer = ApprovalSigner(store: store, registrar: SignInKeyRegistrar(services: services, web: web))
        return try await signer.sign(reason: reason, challenge: challenge)
    }
}
