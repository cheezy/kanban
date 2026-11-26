import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Repeats a read once after a failure that a restart or a deploy of the server
/// can cause. A write is never repeated, because it may have been carried out.
struct ReadRetryMiddleware: ClientMiddleware {
    private static let statuses: Set = [502, 503, 504]
    private static let errors: Set<URLError.Code> = [.networkConnectionLost, .cannotConnectToHost]

    let delay: Duration

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        guard request.method == .get else { return try await next(request, body, baseURL) }

        do {
            let (response, responseBody) = try await next(request, body, baseURL)
            guard Self.statuses.contains(response.status.code) else { return (response, responseBody) }
        } catch {
            guard
                let code = (error as? ClientError)?.urlErrorCode,
                Self.errors.contains(code)
            else { throw error }
        }

        try await Task.sleep(for: delay)
        return try await next(request, body, baseURL)
    }
}
