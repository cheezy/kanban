import Foundation

/// A token pair as the Keychain item holds it. `TokenPair` is not `Codable`
/// itself, so nothing else encodes one by accident.
struct StoredTokenPair: Codable {
    let accessToken: String
    let accessTokenExpiresAt: Date
    let refreshToken: String

    init(_ pair: TokenPair) {
        accessToken = pair.accessToken
        accessTokenExpiresAt = pair.accessTokenExpiresAt
        refreshToken = pair.refreshToken
    }

    var pair: TokenPair {
        TokenPair(
            accessToken: accessToken,
            accessTokenExpiresAt: accessTokenExpiresAt,
            refreshToken: refreshToken
        )
    }
}
