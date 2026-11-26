import Foundation
import HTTPTypes
import Testing

@testable import StrideKit

@Suite(.timeLimit(.minutes(1)))
struct OAuthFlowTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let key = String(repeating: "A", count: 87)

    private let attempt = OAuthAttempt(verifier: "EXAMPLE-verifier", state: "EXAMPLE-state")
    private let device = DeviceDetails(
        name: "Pat's iPad",
        deviceClass: .tablet,
        model: "iPad13,18",
        osVersion: "17.4",
        appVersion: "1.0.0",
        locale: "fr-CA",
        timeZone: "America/Toronto"
    )
    private let signedIn: SignedInDevice

    init() async throws {
        signedIn = try await SignedInDevice()
    }

    private func trade(with server: FakeServer) async throws(SignInError) -> TokenPair {
        try await OAuthFlow.exchange(
            "EXAMPLE-code",
            of: attempt,
            device: device,
            approvalPublicKey: Self.key,
            using: signedIn.api(server),
            now: { Self.now }
        )
    }

    @Test("trades the code for a token pair that expires when the server says")
    func exchange() async throws {
        let server = FakeServer { _ in .tokens(.example(2)) }

        let pair = try await trade(with: server)

        #expect(pair == TokenPair(
            accessToken: "EXAMPLE-access-2",
            accessTokenExpiresAt: Self.now.addingTimeInterval(3600),
            refreshToken: "EXAMPLE-refresh-2"
        ))
    }

    @Test("sends the code, the verifier, the device and the approval key in the body")
    func body() async throws {
        let server = FakeServer { _ in .tokens(.example(2)) }

        _ = try await trade(with: server)

        let request = try #require(await server.requests.first)
        #expect(request.operationID == Operations.OauthToken.id)
        #expect(request.request.method == .post)
        #expect(request.request.path == "/oauth/token")
        #expect(try JSONDecoder().decode([String: String].self, from: request.body) == [
            "grant_type": "authorization_code",
            "client_id": "stride-ios",
            "code": "EXAMPLE-code",
            "code_verifier": "EXAMPLE-verifier",
            "redirect_uri": "com.stridelikeaboss.app:/oauth/callback",
            "platform": "ios",
            "device_class": "tablet",
            "model": "iPad13,18",
            "os_version": "17.4",
            "app_version": "1.0.0",
            "locale": "fr-CA",
            "time_zone": "America/Toronto",
            "approval_public_key": Self.key
        ])
    }

    @Test("sends no access token, and nothing secret outside the body")
    func noAuthorization() async throws {
        let server = FakeServer { _ in .tokens(.example(2)) }

        _ = try await trade(with: server)

        let request = try #require(await server.requests.first)
        #expect(request.authorization.isEmpty)
        #expect(request.head.contains("EXAMPLE") == false)
        #expect(request.versions == ["ios/1.0.0 (42)"])
    }

    @Test(
        "a refusal fails the sign-in and is never sent again",
        arguments: [
            ServerAnswer.oauthError("invalid_grant"),
            ServerAnswer.oauthError("invalid_request"),
            ServerAnswer.oauthError("rate_limited", status: .tooManyRequests),
            ServerAnswer(.internalServerError),
            ServerAnswer(.serviceUnavailable),
            ServerAnswer(.unauthorized, #"{"error": "invalid_client"}"#),
            ServerAnswer(.ok, #"{"unexpected": true}"#)
        ]
    )
    func refused(answer: ServerAnswer) async throws {
        let server = FakeServer { _ in answer }

        await #expect(throws: SignInError.failed) { try await trade(with: server) }

        // The server burns a code it refuses, so a second try could only fail.
        #expect(await server.operations == [Operations.OauthToken.id])
    }

    @Test("an unreachable server is a network error, tried once")
    func unreachable() async throws {
        let server = FakeServer { _ in throw URLError(.notConnectedToInternet) }

        await #expect(throws: SignInError.network) { try await trade(with: server) }

        #expect(await server.operations == [Operations.OauthToken.id])
    }

    @Test("a cancelled request cancels the sign-in")
    func cancelled() async throws {
        let server = FakeServer { _ in throw URLError(.cancelled) }

        await #expect(throws: SignInError.cancelled) { try await trade(with: server) }
    }

    @Test("the stored sign-in stays as it was")
    func leavesStore() async throws {
        let server = FakeServer { _ in .oauthError("invalid_grant") }

        await #expect(throws: SignInError.failed) { try await trade(with: server) }

        #expect(try await signedIn.store.read() == .example(1))
    }
}

extension ServerAnswer: CustomTestStringConvertible {
    var testDescription: String { "\(status.code) \(json ?? "")" }
}
