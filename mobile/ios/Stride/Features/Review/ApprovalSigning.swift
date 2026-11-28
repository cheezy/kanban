import Foundation
import StrideKit

/// Signs one approval challenge after Face ID, Touch ID or the passcode. The
/// app's is `DeviceApprovalSigning`; a debug build started with
/// `-StrideStubApproval` uses `StubApprovalSigning`, which asks no one.
@MainActor
protocol ApprovalSigning {
    /// Signs the challenge `challenge` fetches, after asking with `reason`.
    /// `web` opens the sign-in a new approval key needs. An error `challenge`
    /// throws is rethrown unchanged.
    func sign(
        reason: String,
        web: any WebAuthenticating,
        challenge: @escaping @Sendable () async throws -> Components.Schemas.ApprovalChallenge
    ) async throws -> ApprovalSigner.Outcome
}
