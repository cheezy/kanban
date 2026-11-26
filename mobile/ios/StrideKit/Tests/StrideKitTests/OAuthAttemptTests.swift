import Foundation
import Testing

@testable import StrideKit

struct OAuthAttemptTests {
    /// The verifier the server's PKCE test uses, with the challenge it expects.
    private static let verifier = "dBjftJeZ4CVP-mA92Q-NtmWN3zLz1wf-kGk2XBxwMLk"
    private static let challenge = "HUoRTFnB9N6pVJ_xr0vr25hif8B2Vm4l6NLwgAqpcgw"

    private let attempt = OAuthAttempt(verifier: Self.verifier, state: "EXAMPLE-state")
    private let phone = DeviceDetails(name: "Pat's iPhone", deviceClass: .phone)

    // MARK: The verifier and the state

    @Test("the challenge is the verifier's SHA-256 in base64url without padding")
    func challenge() {
        #expect(attempt.challenge == Self.challenge)
    }

    @Test("each attempt has its own 43-character verifier and state")
    func randomValues() {
        let attempts = (0..<20).map { _ in OAuthAttempt() }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

        #expect(Set(attempts.map(\.verifier)).count == 20)
        #expect(Set(attempts.map(\.state)).count == 20)
        for attempt in attempts {
            #expect(attempt.verifier.count == 43)
            #expect(attempt.state.count == 43)
            #expect(attempt.verifier != attempt.state)
            #expect(attempt.verifier.unicodeScalars.allSatisfy(allowed.contains))
            #expect(attempt.state.unicodeScalars.allSatisfy(allowed.contains))
        }
    }

    // MARK: The authorize page

    @Test("the authorize page is on the Stride server and asks for a code with S256")
    func authorizeURL() throws {
        let url = attempt.authorizeURL(for: phone)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })

        #expect(components.scheme == "https")
        #expect(components.host == "www.stridelikeaboss.com")
        #expect(components.path == "/oauth/authorize")
        #expect(query == [
            "response_type": "code",
            "client_id": "stride-ios",
            "redirect_uri": "com.stridelikeaboss.app:/oauth/callback",
            "code_challenge_method": "S256",
            "code_challenge": Self.challenge,
            "state": "EXAMPLE-state",
            "device_name": "Pat's iPhone",
            "device_class": "phone"
        ])
    }

    @Test("the verifier never reaches the authorize page")
    func noVerifierInURL() {
        #expect(attempt.authorizeURL(for: phone).absoluteString.contains(Self.verifier) == false)
    }

    @Test("a plus, an ampersand or a space in the device name reaches the server as itself")
    func encodedName() throws {
        let device = DeviceDetails(name: "A+B & C=D é", deviceClass: .tablet)
        let url = attempt.authorizeURL(for: device)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)

        #expect(query.contains("device_name=A%2BB%20%26%20C%3DD%20%C3%A9"))
        #expect(query.contains("device_class=tablet"))
    }

    // MARK: The callback

    @Test("reads the code from the callback this attempt asked for")
    func code() throws {
        let callback = URL(string: "com.stridelikeaboss.app:/oauth/callback?code=EXAMPLE-code&state=EXAMPLE-state")!

        #expect(try attempt.code(from: callback) == "EXAMPLE-code")
    }

    @Test(
        "the state parameter must match",
        arguments: [
            "com.stridelikeaboss.app:/oauth/callback?code=EXAMPLE-code&state=another",
            "com.stridelikeaboss.app:/oauth/callback?code=EXAMPLE-code",
            "com.stridelikeaboss.app:/oauth/callback?code=EXAMPLE-code&state=",
            "com.stridelikeaboss.app:/oauth/callback?code=EXAMPLE-code&state=EXAMPLE-state&state=another",
            "com.stridelikeaboss.app:/oauth/callback?code=EXAMPLE-code&state=EXAMPLE-STATE",
            "com.stridelikeaboss.app:/oauth/callback?error=access_denied&state=another",
            "com.stridelikeaboss.app:/oauth/callback?error=access_denied"
        ]
    )
    func wrongState(callback: String) {
        #expect(throws: SignInError.failed) { try attempt.code(from: URL(string: callback)!) }
    }

    @Test(
        "refuses a callback to another place",
        arguments: [
            "https://www.stridelikeaboss.com/oauth/callback?code=EXAMPLE-code&state=EXAMPLE-state",
            "com.stridelikeaboss.other:/oauth/callback?code=EXAMPLE-code&state=EXAMPLE-state",
            "com.stridelikeaboss.app://oauth/callback?code=EXAMPLE-code&state=EXAMPLE-state",
            "com.stridelikeaboss.app:/oauth/other?code=EXAMPLE-code&state=EXAMPLE-state",
            "com.stridelikeaboss.app:/oauth/callback/?code=EXAMPLE-code&state=EXAMPLE-state"
        ]
    )
    func wrongPlace(callback: String) {
        #expect(throws: SignInError.failed) { try attempt.code(from: URL(string: callback)!) }
    }

    @Test(
        "refuses a callback without one code",
        arguments: [
            "com.stridelikeaboss.app:/oauth/callback?state=EXAMPLE-state",
            "com.stridelikeaboss.app:/oauth/callback?code=&state=EXAMPLE-state",
            "com.stridelikeaboss.app:/oauth/callback?code&state=EXAMPLE-state",
            "com.stridelikeaboss.app:/oauth/callback?code=one&code=two&state=EXAMPLE-state"
        ]
    )
    func noCode(callback: String) {
        #expect(throws: SignInError.failed) { try attempt.code(from: URL(string: callback)!) }
    }

    @Test("a person who presses Cancel on the web cancels the sign-in")
    func deniedOnWeb() {
        let callback = URL(string: "com.stridelikeaboss.app:/oauth/callback?error=access_denied&state=EXAMPLE-state")!

        #expect(throws: SignInError.cancelled) { try attempt.code(from: callback) }
    }

    @Test("any other error from the web fails the sign-in, even with a code")
    func otherError() {
        let callback = URL(
            string: "com.stridelikeaboss.app:/oauth/callback?error=server_error&code=EXAMPLE-code&state=EXAMPLE-state"
        )!

        #expect(throws: SignInError.failed) { try attempt.code(from: callback) }
    }
}
