import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Reports the app's platform and version in one header, with every request.
struct AppVersionMiddleware: ClientMiddleware {
    let version: AppVersion

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        // Replaces a value the caller passed: the server ignores a repeated header.
        request.headerFields[.strideApp] = version.headerValue

        return try await next(request, body, baseURL)
    }
}
