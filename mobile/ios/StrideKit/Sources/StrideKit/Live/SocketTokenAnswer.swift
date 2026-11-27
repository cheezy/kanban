import OpenAPIRuntime

/// What the server said when asked for a socket token. Its description and
/// mirror never show the token.
enum SocketTokenAnswer: Sendable, Equatable {
    /// A token for one connect, valid for 60 seconds.
    case token(String)

    /// The sign-in has ended: the device was revoked or its refresh was refused.
    case signedOut

    /// No live updates for now: the plan lacks the app, or the app needs an update.
    case unavailable

    /// Anything else, such as no network or a busy server. Worth asking again.
    case failed

    /// Asks the server for a token. The API client sends the access token and
    /// refreshes it once when it has expired.
    static func asking(_ api: any StrideAPI) async -> SocketTokenAnswer {
        do {
            switch try await api.createMySocketToken() {
            case .created(let created):
                return .token(try created.body.json.data.token)
            case .unauthorized:
                return .signedOut
            case .forbidden, .upgradeRequired:
                return .unavailable
            default:
                return .failed
            }
        } catch let error as ClientError where error.underlyingError as? APIClientError == .signedOut {
            return .signedOut
        } catch {
            return .failed
        }
    }
}

extension SocketTokenAnswer: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String {
        switch self {
        case .token: "token(<redacted>)"
        case .signedOut: "signedOut"
        case .unavailable: "unavailable"
        case .failed: "failed"
        }
    }

    var debugDescription: String { description }

    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .enum) }
}
