import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Answers every request with one response.
struct StubTransport: ClientTransport {
    let status: HTTPResponse.Status
    let headers: HTTPFields
    let json: String

    init(status: HTTPResponse.Status = .ok, headers: HTTPFields = [:], json: String) {
        self.status = status
        self.headers = headers
        self.json = json
    }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var fields = headers
        fields[.contentType] = "application/json"
        return (HTTPResponse(status: status, headerFields: fields), HTTPBody(json))
    }
}
