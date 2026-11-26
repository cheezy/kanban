import Foundation
import Testing

@testable import StrideKit

@Suite(.timeLimit(.minutes(1)))
struct AppAccessTests {
    @Test("a person with the Organization plan gets in")
    func unlocked() async {
        #expect(await AppAccess.load(using: FixtureAPI().client) == .unlocked)
    }

    @Test("a person without the Organization plan is locked out")
    func locked() async throws {
        let api = FixtureAPI(replacing: try FixtureAPI.lockedPlan).client

        #expect(await AppAccess.load(using: api) == .locked)
    }

    @Test("an unreachable server says nothing either way")
    func unreachable() async {
        let api = FixtureAPI(unreachable: [Operations.GetMe.id]).client

        #expect(await AppAccess.load(using: api) == .unknown)
    }

    @Test(
        "a refusal or an answer that does not decode says nothing either way",
        arguments: [ServerAnswer(.internalServerError), ServerAnswer(.ok, "{}"), .unauthorized]
    )
    func refused(answer: ServerAnswer) async throws {
        let device = try await SignedInDevice()
        let server = FakeServer { $0.isRefresh ? .oauthError("invalid_grant") : answer }

        #expect(await AppAccess.load(using: device.api(server)) == .unknown)
    }
}
