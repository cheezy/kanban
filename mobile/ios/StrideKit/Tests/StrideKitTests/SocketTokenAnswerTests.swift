import Foundation
import HTTPTypes
import Testing

@testable import StrideKit

@Suite(.timeLimit(.minutes(1)))
struct SocketTokenAnswerTests {
    private let device: SignedInDevice

    init() async throws {
        device = try await SignedInDevice()
    }

    @Test("a created token is the answer")
    func created() async {
        let answer = await SocketTokenAnswer.asking(FixtureAPI().client)

        #expect(answer == .token("EXAMPLE-socket-token-for-previews-only"))
    }

    @Test("asks the server once for each connect")
    func asksEachTime() async {
        let server = FakeServer { _ in Self.created }
        let api = device.api(server)

        _ = await SocketTokenAnswer.asking(api)
        _ = await SocketTokenAnswer.asking(api)

        #expect(await server.operations == [Operations.CreateMySocketToken.id, Operations.CreateMySocketToken.id])
    }

    @Test("a revoked device is signed out, and its tokens are cleared")
    func revoked() async throws {
        let server = FakeServer { $0.isRefresh ? .oauthError("invalid_grant") : .unauthorized }

        let answer = await SocketTokenAnswer.asking(device.api(server))

        #expect(answer == .signedOut)
        #expect(device.keychain.items.isEmpty)
        #expect(await server.operations == [Operations.CreateMySocketToken.id, Operations.OauthToken.id])
    }

    @Test("a refused access token after a refresh is signed out")
    func refusedAfterRefresh() async {
        let server = FakeServer { $0.isRefresh ? .tokens(.example(2)) : .unauthorized }

        let answer = await SocketTokenAnswer.asking(device.api(server))

        #expect(answer == .signedOut)
    }

    @Test("a plan without the app or an outdated app is unavailable", arguments: [
        ServerAnswer(.forbidden, #"{"error": "plan_required", "feature": "mobile_app", "message": "EXAMPLE"}"#),
        .updateRequired(storeURL: "https://apps.apple.com/app/id0000000000")
    ])
    func unavailable(answer: ServerAnswer) async {
        let server = FakeServer { _ in answer }

        #expect(await SocketTokenAnswer.asking(device.api(server)) == .unavailable)
    }

    @Test("a busy server or a lost network is worth asking again", arguments: [
        ServerAnswer(.internalServerError),
        ServerAnswer(.tooManyRequests, #"{"error": "rate_limited"}"#)
    ])
    func failed(answer: ServerAnswer) async {
        let server = FakeServer { _ in answer }

        #expect(await SocketTokenAnswer.asking(device.api(server)) == .failed)
    }

    @Test("no network is worth asking again")
    func offline() async {
        let api = FixtureAPI(unreachable: [Operations.CreateMySocketToken.id]).client

        #expect(await SocketTokenAnswer.asking(api) == .failed)
    }

    @Test("never shows the token")
    func redacted() {
        let answer = SocketTokenAnswer.token("EXAMPLE-socket-secret")

        for text in [String(describing: answer), String(reflecting: answer), "\(answer)", "\([answer])"] {
            #expect(!text.contains("EXAMPLE-socket-secret"), "\(text)")
        }
        #expect(Mirror(reflecting: answer).children.isEmpty)
    }

    private static let created = ServerAnswer(
        .created,
        #"{"data": {"token": "EXAMPLE-socket-token", "expires_at": "2026-11-20T09:31:00Z", "expires_in": 60}}"#
    )
}
