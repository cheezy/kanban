#if DEBUG
import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Answers the client from `mobile/shared/fixtures`, for previews and tests. An
/// operation whose success has no body gets its status alone.
///
/// The generated client still builds each request and decodes each response, so
/// a preview shows exactly what the app would read. It reads the fixtures from
/// the source tree, which a preview or a simulator test can reach and a device
/// cannot, and it is left out of release builds.
public struct FixtureAPI: ClientTransport {
    /// Named by `operationId`, as the files in `mobile/shared/fixtures` are.
    private let replacements: [String: Data]

    /// Replaces the bodies of some operations, keyed by `Operations.<Name>.id`.
    public init(replacing replacements: [String: Data] = [:]) {
        self.replacements = replacements
    }

    public var client: some StrideAPI {
        StrideClient.make(transport: self)
    }

    public func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let status = Self.status(of: operationID)
        guard status != .noContent else { return (HTTPResponse(status: status), nil) }

        let data = try replacements[operationID] ?? Self.fixture(named: operationID)
        let headers: HTTPFields = [.contentType: "application/json"]
        return (HTTPResponse(status: status, headerFields: headers), HTTPBody(data))
    }

    static let directory = URL(filePath: #filePath)
        .appending(path: "../../../../../../shared/fixtures")
        .standardizedFileURL

    static func fixture(named operationID: String) throws -> Data {
        try Data(contentsOf: directory.appending(path: "\(operationID).json"))
    }

    /// The contract's success status, which the client needs to pick the type it
    /// decodes. `FixtureDecodingTests` calls every operation with a fixture, and
    /// `FixtureAPITests` the two with no body, so a wrong one fails.
    private static func status(of operationID: String) -> HTTPResponse.Status {
        switch operationID {
        case Operations.CreateMySocketToken.id,
            Operations.CreateMyReviewApprovalChallenge.id,
            Operations.CaptureMyTask.id,
            Operations.CommentOnMyTask.id:
            .created
        case Operations.SignOutCurrentDevice.id, Operations.RevokeMyDevice.id:
            .noContent
        default:
            .ok
        }
    }
}
#endif
