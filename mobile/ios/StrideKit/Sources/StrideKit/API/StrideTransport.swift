import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Refuses a request for any server but `StrideClient.serverURL`, including one
/// a middleware changed, so a token never leaves for another host.
struct StrideTransport: ClientTransport {
    let next: any ClientTransport

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        guard baseURL == StrideClient.serverURL else { throw UnexpectedServerError() }

        return try await next.send(request, body: body, baseURL: baseURL, operationID: operationID)
    }
}
