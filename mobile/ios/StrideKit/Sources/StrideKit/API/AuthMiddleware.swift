import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Sends the access token, and when the server refuses it, gets a new one and
/// repeats the request once. The server refuses a token before it does anything,
/// so repeating a write is safe.
struct AuthMiddleware: ClientMiddleware {
    /// The operations that take no access token. A refresh is one of them.
    private static let withoutToken: Set = [Operations.OauthToken.id, Operations.OauthRevoke.id]

    let refresher: RefreshCoordinator

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        if Self.withoutToken.contains(operationID) {
            return try await next(request, body, baseURL)
        }

        let session = try await refresher.session()
        let (response, responseBody) = try await next(request.authorized(by: session), body, baseURL)
        guard response.status == .unauthorized else { return (response, responseBody) }

        let newSession = try await refresher.session(replacing: session)
        return try await next(request.authorized(by: newSession), body, baseURL)
    }
}
