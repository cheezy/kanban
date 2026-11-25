import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Records where each request would go, and answers none of them.
actor RecordingTransport: ClientTransport {
    private(set) var baseURLs: [URL] = []

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        baseURLs.append(baseURL)
        return (HTTPResponse(status: .serviceUnavailable), nil)
    }
}
