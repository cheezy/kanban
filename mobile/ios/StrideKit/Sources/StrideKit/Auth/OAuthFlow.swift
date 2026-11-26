import Foundation
import OpenAPIRuntime

/// The names the sign-in shares with the server, and the exchange of an
/// authorization code for the device's first token pair.
public enum OAuthFlow {
    static let clientID = "stride-ios"

    /// The scheme `ASWebAuthenticationSession` waits for. The server sends the
    /// browser only to `redirectURI`, and the callback is checked against it.
    public static let callbackScheme = "com.stridelikeaboss.app"
    static let callbackPath = "/oauth/callback"
    static let redirectURI = "\(callbackScheme):\(callbackPath)"

    /// Trades the code from `attempt`'s callback for the device's token pair. The
    /// server creates the device from this request, with `approvalPublicKey` as
    /// the key that later approvals are checked against.
    ///
    /// Its errors hold no part of the request or the answer, which have tokens.
    public static func exchange(
        _ code: String,
        of attempt: OAuthAttempt,
        device: DeviceDetails,
        approvalPublicKey: String,
        using api: any StrideAPI,
        now: @Sendable () -> Date = { .now }
    ) async throws(SignInError) -> TokenPair {
        let request = Components.Schemas.OAuthTokenRequest(
            grantType: .authorizationCode,
            clientId: .strideIos,
            code: code,
            codeVerifier: attempt.verifier,
            redirectUri: .com_stridelikeaboss_app_colon_OauthCallback,
            platform: .ios,
            deviceClass: device.deviceClass == .tablet ? .tablet : .phone,
            model: device.model,
            osVersion: device.osVersion,
            appVersion: device.appVersion,
            locale: device.locale,
            timeZone: device.timeZone,
            approvalPublicKey: approvalPublicKey
        )

        let output: Operations.OauthToken.Output
        do {
            output = try await api.oauthToken(body: .json(request))
        } catch {
            throw SignInError(classifying: error)
        }

        // Any refusal burned the code, so the person starts again.
        guard case .ok(let response) = output, let tokens = try? response.body.json else {
            throw .failed
        }

        return TokenPair(
            accessToken: tokens.accessToken,
            accessTokenExpiresAt: now().addingTimeInterval(TimeInterval(tokens.expiresIn)),
            refreshToken: tokens.refreshToken
        )
    }
}
