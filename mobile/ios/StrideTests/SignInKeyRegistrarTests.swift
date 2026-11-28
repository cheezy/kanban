import Foundation
import Testing

@testable import Stride
@testable import StrideKit

/// The new sign-in `ApprovalSigner` asks for when it needs a new approval key.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SignInKeyRegistrarTests {
    private static func services(
        store: MemorySignInStore,
        api: FixtureAPI = FixtureAPI(),
        keyMaker: StubApprovalKeyMaker = StubApprovalKeyMaker()
    ) -> SignInServices {
        SignInServices(
            store: store,
            api: api.client,
            keyMaker: keyMaker,
            device: DeviceDetails(name: "Pat's iPhone", deviceClass: .phone)
        )
    }

    @Test("a completed sign-in saves the new key and says so")
    func registers() async throws {
        let store = MemorySignInStore(signedIn: true)
        let registrar = SignInKeyRegistrar(services: Self.services(store: store), web: StubWebAuthenticator(outcome: .allow))

        #expect(try await registrar.registerNewKey())
        #expect(await store.saved.count == 1)
        #expect(await store.savedKeys.count == 1)
    }

    @Test("closing or cancelling the sign-in registers nothing", arguments: [StubWebAuthenticator.Outcome.cancel, .deny])
    func cancelled(outcome: StubWebAuthenticator.Outcome) async throws {
        let store = MemorySignInStore(signedIn: true)
        let registrar = SignInKeyRegistrar(services: Self.services(store: store), web: StubWebAuthenticator(outcome: outcome))

        #expect(try await registrar.registerNewKey() == false)
        #expect(await store.saved.isEmpty)
    }

    @Test("a sign-in that fails throws its reason")
    func fails() async {
        let store = MemorySignInStore(signedIn: true)
        let offline = SignInKeyRegistrar(
            services: Self.services(store: store, api: FixtureAPI(unreachable: [Operations.OauthToken.id])),
            web: StubWebAuthenticator(outcome: .allow)
        )
        await #expect(throws: SignInError.network) { try await offline.registerNewKey() }

        let noPasscode = SignInKeyRegistrar(
            services: Self.services(store: store, keyMaker: StubApprovalKeyMaker(failure: .passcodeNotSet)),
            web: StubWebAuthenticator(outcome: .allow)
        )
        await #expect(throws: SignInError.passcodeNotSet) { try await noPasscode.registerNewKey() }
        #expect(await store.saved.isEmpty)
    }
}
