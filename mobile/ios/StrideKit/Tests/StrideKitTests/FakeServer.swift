import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Records every request and answers it as the test says.
actor FakeServer: ClientTransport {
    private let answer: @Sendable (SentRequest) async throws -> ServerAnswer
    private(set) var requests: [SentRequest] = []

    init(answer: @escaping @Sendable (SentRequest) async throws -> ServerAnswer) {
        self.answer = answer
    }

    var operations: [String] { requests.map(\.operationID) }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var data = Data()
        if let body { data = try await Data(collecting: body, upTo: 1024 * 1024) }

        let sent = SentRequest(operationID: operationID, request: request, body: data)
        requests.append(sent)

        let answer = try await answer(sent)
        return (answer.response, answer.json.map { HTTPBody($0) })
    }
}
