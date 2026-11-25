import Foundation

/// The access and refresh token of a signed-in device.
///
/// Its description, debug description and mirror hold no token, so printing,
/// dumping or snapshotting a pair shows neither.
public struct TokenPair: Equatable, Sendable {
    public let accessToken: String
    public let accessTokenExpiresAt: Date
    public let refreshToken: String

    public init(accessToken: String, accessTokenExpiresAt: Date, refreshToken: String) {
        self.accessToken = accessToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshToken = refreshToken
    }
}

extension TokenPair: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "TokenPair(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
