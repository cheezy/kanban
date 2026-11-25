import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Sends every request on to another base URL.
struct BaseURLMiddleware: ClientMiddleware {
    let url: URL

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        try await next(request, body, url)
    }
}
