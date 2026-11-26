#if DEBUG
import Foundation
import StrideKit

/// How a debug build started with `-StrideStubSignIn` answers a sign-in.
enum StubSignIn: String {
    /// The web allows the device, and the plan includes the app.
    case allow
    /// The person presses Cancel.
    case cancel
    /// The web allows the device, and the plan does not include the app.
    case locked
    /// The token exchange cannot reach the server.
    case offline

    init?(arguments: [String]) {
        guard
            let index = arguments.firstIndex(of: SignInModel.stubSignInArgument),
            arguments.indices.contains(index + 1)
        else { return nil }

        self.init(rawValue: arguments[index + 1])
    }

    @MainActor
    func model() -> SignInModel {
        let replacements = self == .locked ? (try? FixtureAPI.lockedPlan) ?? [:] : [:]
        let unreachable: Set = self == .offline ? [Operations.OauthToken.id] : []

        return SignInModel(
            services: SignInServices(
                store: MemorySignInStore(),
                api: FixtureAPI(replacing: replacements, unreachable: unreachable).client,
                keyMaker: StubApprovalKeyMaker(),
                device: .current()
            ),
            authenticator: StubWebAuthenticator(outcome: self == .cancel ? .cancel : .allow)
        )
    }
}
#endif
