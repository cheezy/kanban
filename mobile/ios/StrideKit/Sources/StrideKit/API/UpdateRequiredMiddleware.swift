import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Tells `update` when the server answers 426, which it does whether or not the
/// access token is good. The answer goes on to the caller, without its body when
/// that is too long or cannot be read.
struct UpdateRequiredMiddleware: ClientMiddleware {
    private static let maximumSize = 16 * 1024

    let update: AppUpdateState

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let (response, responseBody) = try await next(request, body, baseURL)
        guard response.status.code == 426 else { return (response, responseBody) }

        let data = await content(of: responseBody)
        await update.requireUpdate(from: AppStoreLink.url(in: data))

        return (response, data.map { HTTPBody($0) })
    }

    /// Nil when there is no body, or it is too long to be the server's.
    private func content(of body: HTTPBody?) async -> Data? {
        guard let body else { return nil }

        return try? await Data(collecting: body, upTo: Self.maximumSize)
    }
}
