import Foundation

extension Data {
    /// Base64url without padding (RFC 4648 section 5), as PKCE and the approval
    /// key use it.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
