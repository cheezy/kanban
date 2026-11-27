/// Where `LiveChannel`'s connection stands.
public enum LiveState: Sendable, Equatable {
    /// Nobody is listening, so there is no connection.
    case idle

    /// Asking for a socket token, or opening the socket.
    case connecting

    /// The socket is open and carries the channels its listeners want.
    case live

    /// The connection dropped or was refused. It connects again after a pause.
    case waiting

    /// The sign-in has ended, as it does when the device is revoked. It does not
    /// connect again until a listener arrives after the next sign-in.
    case signedOut

    /// The server does not serve live updates now: the plan lacks the app, or the
    /// app needs an update. It asks again on `resume()`.
    case unavailable
}
