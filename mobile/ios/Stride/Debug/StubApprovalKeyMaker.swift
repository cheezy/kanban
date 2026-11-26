#if DEBUG
import StrideKit

/// Makes a software key at once, or fails as the test says.
struct StubApprovalKeyMaker: ApprovalKeyMaking {
    var failure: SignInError?

    func makeKey() async throws(SignInError) -> ApprovalKey {
        if let failure { throw failure }

        return .example()
    }
}
#endif
