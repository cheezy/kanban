#if DEBUG
import Foundation
import StrideKit

/// How a debug build answers Face ID, chosen with `-StrideStubApproval`
/// followed by `match`, `nomatch` or `passcode`. A build that signs in through the stub
/// matches unless told otherwise.
enum StubApprovalSigning: String, ApprovalSigning {
    /// The face matches: the challenge is fetched and signed with an example
    /// signature the fixtures accept.
    case match
    /// The face does not match and the person closes the prompt. The
    /// challenge is fetched first, as `ApprovalSigner` fetches it before it
    /// asks for the face, and nothing is sent.
    case nomatch
    /// The device has no passcode, so no key can be used, and nothing is
    /// fetched or sent.
    case passcode

    nonisolated static let argument = "-StrideStubApproval"

    init?(arguments: [String]) {
        if let index = arguments.firstIndex(of: Self.argument), arguments.indices.contains(index + 1) {
            self.init(rawValue: arguments[index + 1])
        } else if StubSignIn(arguments: arguments) != nil {
            self = .match
        } else {
            return nil
        }
    }

    func sign(
        reason: String,
        web: any WebAuthenticating,
        challenge: @escaping @Sendable () async throws -> Components.Schemas.ApprovalChallenge
    ) async throws -> ApprovalSigner.Outcome {
        switch self {
        case .match: return .signed(try SignedApproval.example(for: try await challenge()))
        case .nomatch:
            _ = try await challenge()
            return .cancelled
        case .passcode: throw ApprovalSignerError.passcodeNotSet
        }
    }
}
#endif
