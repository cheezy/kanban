import CryptoKit
import Foundation

/// One try at signing in, with its own PKCE verifier and state (RFC 7636, RFC 8252).
///
/// Make a new attempt for every press of Sign in: the server burns a code whose
/// verifier is wrong, and a state used twice would let an old callback through.
public struct OAuthAttempt: Sendable {
    /// Sent only in the token exchange, so the code alone is worth nothing.
    let verifier: String

    /// Comes back in the callback, which proves the callback answers this attempt.
    let state: String

    public init() {
        self.init(verifier: Self.randomValue(), state: Self.randomValue())
    }

    init(verifier: String, state: String) {
        self.verifier = verifier
        self.state = state
    }

    /// The S256 challenge: the verifier's SHA-256, in base64url without padding.
    var challenge: String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }

    /// The page that signs the person in on the web and asks them to allow this
    /// device.
    public func authorizeURL(for device: DeviceDetails) -> URL {
        let query: [(String, String)] = [
            ("response_type", "code"),
            ("client_id", OAuthFlow.clientID),
            ("redirect_uri", OAuthFlow.redirectURI),
            ("code_challenge_method", "S256"),
            ("code_challenge", challenge),
            ("state", state),
            ("device_name", device.name),
            ("device_class", device.deviceClass.rawValue)
        ]
        var components = URLComponents()
        components.scheme = "https"
        components.host = StrideClient.serverURL.host()
        components.path = "/oauth/authorize"
        components.percentEncodedQuery = query
            .map { "\($0.0)=\(Self.percentEncoded($0.1))" }
            .joined(separator: "&")

        // Every part is set above and every value is percent-encoded.
        return components.url!
    }

    /// The authorization code in `callback`.
    ///
    /// Throws `cancelled` when the person pressed Cancel on the web, and `failed`
    /// for a callback this attempt did not ask for: another scheme or path, another
    /// state, a repeated parameter, or no code.
    public func code(from callback: URL) throws(SignInError) -> String {
        guard
            let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
            components.scheme == OAuthFlow.callbackScheme,
            components.host == nil,
            components.path == OAuthFlow.callbackPath
        else { throw .failed }

        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            let matching = items.filter { $0.name == name }
            return matching.count == 1 ? matching[0].value : nil
        }

        // The state first, so a callback another page made up cannot even cancel.
        guard value("state") == state else { throw .failed }
        if let error = value("error") { throw error == "access_denied" ? .cancelled : .failed }
        guard let code = value("code"), code.isEmpty == false else { throw .failed }

        return code
    }

    /// 32 random bytes in base64url: 43 characters, inside what RFC 7636 allows
    /// for a verifier and what the server allows for a state.
    private static func randomValue() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64URLEncodedString()
    }

    /// Leaves only RFC 3986's unreserved characters, so a `+` or a space in the
    /// device name reaches the server as itself.
    private static func percentEncoded(_ value: String) -> String {
        var unreserved = CharacterSet.alphanumerics.intersection(.init(charactersIn: "\u{0}"..."\u{7F}"))
        unreserved.insert(charactersIn: "-._~")
        // Every string can be percent-encoded.
        return value.addingPercentEncoding(withAllowedCharacters: unreserved)!
    }
}
