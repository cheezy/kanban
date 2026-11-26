/// Why a request was not sent or not repeated. No case holds a token.
public enum APIClientError: Error, Equatable {
    /// The sign-in the request belongs to has ended: no pair is stored, the server
    /// refused to refresh it, or someone signed out or in meanwhile.
    case signedOut

    /// The access token needs a refresh, and the server did not answer with a new
    /// pair or with a refusal. The device is still signed in.
    case refreshUnavailable
}
