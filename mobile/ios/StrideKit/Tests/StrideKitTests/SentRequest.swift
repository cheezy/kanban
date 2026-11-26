import Foundation
import HTTPTypes

@testable import StrideKit

/// A request that reached `FakeServer`.
struct SentRequest {
    let operationID: String
    let request: HTTPRequest
    let body: Data

    var authorization: [String] { request.headerFields[values: .authorization] }
    var versions: [String] { request.headerFields[values: HTTPField.Name("X-Stride-App")!] }

    /// The request without its body, as one text.
    var head: String {
        let fields = request.headerFields.map { "\($0.name): \($0.value)" }
        return ([request.method.rawValue, request.path ?? ""] + fields).joined(separator: "\n")
    }
}

extension SentRequest {
    var isRefresh: Bool { operationID == "oauthToken" }

    /// The answer of a server that accepts only the access token of `pair`, and
    /// gives that pair for any refresh token.
    func answer(accepting pair: TokenPair) -> ServerAnswer {
        if isRefresh { return .tokens(pair) }
        return authorization == ["Bearer \(pair.accessToken)"] ? .boards : .unauthorized
    }
}
