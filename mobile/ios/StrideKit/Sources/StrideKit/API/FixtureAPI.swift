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
    private let statuses: [String: Int]
    private let unreachable: Set<String>
    private let isOffline: @Sendable () -> Bool
    private let onSend: @Sendable (_ operationID: String, _ body: Data?) -> Void

    /// Replaces the bodies of some operations, keyed by `Operations.<Name>.id`,
    /// and fails the `unreachable` ones as if the device were offline. While
    /// `isOffline` returns true every operation fails that way, so a test can
    /// take the device offline after a first answer.
    ///
    /// `statuses` answers an operation with another HTTP status, such as 409,
    /// with its replaced body or none. `onSend` hears each operation the
    /// client sends, with its request body, before the answer.
    public init(
        replacing replacements: [String: Data] = [:],
        statuses: [String: Int] = [:],
        unreachable: Set<String> = [],
        isOffline: @escaping @Sendable () -> Bool = { false },
        onSend: @escaping @Sendable (_ operationID: String, _ body: Data?) -> Void = { _, _ in }
    ) {
        self.replacements = replacements
        self.statuses = statuses
        self.unreachable = unreachable
        self.isOffline = isOffline
        self.onSend = onSend
    }

    /// `getMe` for a person whose plan does not include the app.
    public static var lockedPlan: [String: Data] {
        get throws {
            let fixture = try fixture(named: Operations.GetMe.id)
            guard
                var me = try JSONSerialization.jsonObject(with: fixture) as? [String: Any],
                var data = me["data"] as? [String: Any]
            else { throw CocoaError(.coderReadCorrupt) }

            data["app_unlocked"] = false
            me["data"] = data
            return [Operations.GetMe.id: try JSONSerialization.data(withJSONObject: me)]
        }
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
        if isOffline() || unreachable.contains(operationID) { throw URLError(.notConnectedToInternet) }

        var sent: Data?
        if let body { sent = try await Data(collecting: body, upTo: 1 << 20) }
        onSend(operationID, sent)

        if let code = statuses[operationID] {
            let status = HTTPResponse.Status(code: code)
            guard let data = replacements[operationID] else { return (HTTPResponse(status: status), nil) }
            return (HTTPResponse(status: status, headerFields: [.contentType: "application/json"]), HTTPBody(data))
        }

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
