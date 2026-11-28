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
    private let onRequest: @Sendable (_ operationID: String, _ headers: HTTPFields, _ body: Data?) -> Void
    private let answer: @Sendable (_ operationID: String) -> Data?
    private let pickStatus: @Sendable (_ operationID: String) -> Int?
    private let hold: @Sendable (_ operationID: String) async -> Void

    /// Replaces the bodies of some operations, keyed by `Operations.<Name>.id`,
    /// and fails the `unreachable` ones as if the device were offline. While
    /// `isOffline` returns true every operation fails that way, so a test can
    /// take the device offline after a first answer.
    ///
    /// `statuses` answers an operation with another HTTP status, such as 409,
    /// with its replaced body or none. `onSend` hears each operation the
    /// client sends, with its request body, before the answer. `answering`
    /// picks a body when the operation is sent, before `replacements`, so a
    /// test can change an answer between two calls; nil falls through.
    /// `status` picks a status the same way, before `statuses`, so a test can
    /// answer 409 once and then succeed. `onRequest` hears each request's
    /// header fields and body as it sets out, before an offline or
    /// unreachable operation fails, so a test can tell what a request lost on
    /// the way carried, such as its `Idempotency-Key`. `hold` runs next and
    /// keeps the request on its way until it returns, so a test can let
    /// another call finish first; the status and body are picked after it.
    public init(
        replacing replacements: [String: Data] = [:],
        statuses: [String: Int] = [:],
        unreachable: Set<String> = [],
        isOffline: @escaping @Sendable () -> Bool = { false },
        onSend: @escaping @Sendable (_ operationID: String, _ body: Data?) -> Void = { _, _ in },
        answering answer: @escaping @Sendable (_ operationID: String) -> Data? = { _ in nil },
        status: @escaping @Sendable (_ operationID: String) -> Int? = { _ in nil },
        onRequest: @escaping @Sendable (_ operationID: String, _ headers: HTTPFields, _ body: Data?) -> Void = { _, _, _ in },
        hold: @escaping @Sendable (_ operationID: String) async -> Void = { _ in }
    ) {
        self.replacements = replacements
        self.statuses = statuses
        self.unreachable = unreachable
        self.isOffline = isOffline
        self.onSend = onSend
        self.answer = answer
        self.pickStatus = status
        self.onRequest = onRequest
        self.hold = hold
    }

    /// `getMe` for a person whose plan does not include the app.
    public static var lockedPlan: [String: Data] {
        get throws {
            try editing(Operations.GetMe.id) { data in data["app_unlocked"] = false }
        }
    }

    /// `getMyReview` for a change the server lets no phone approve: 14 files
    /// and 652 changed lines, over the phone's limits. The fixture's three
    /// files gain eleven more, so the file list agrees with the size.
    public static var largeReview: [String: Data] {
        get throws {
            try editing(Operations.GetMyReview.id) { data in
                data["approvable_here"] = false
                data["approvable_here_reason"] = "too_large_for_phone"
                let files = data["files"] as? [[String: Any]] ?? []
                data["files"] = files + largeReviewFiles(from: files.count)
                data["size"] = [
                    "files": 14,
                    "files_unknown": false,
                    "changed_lines": 652,
                    "truncated": false,
                    "large_change": true,
                ] as [String: Any]
            }
        }
    }

    /// The eleven files `largeReview` adds to the fixture's three, from index
    /// `start`: 464 changed lines, so with the fixture's 188 the change has
    /// 652.
    private static func largeReviewFiles(from start: Int) -> [[String: Any]] {
        (0..<11).map { offset in
            [
                "index": start + offset,
                "path": "lib/kanban/export/part_\(offset + 1).ex",
                "additions": offset == 10 ? 20 : 42,
                "deletions": offset == 10 ? 4 : 2,
                "truncated": false,
                "flagged": false,
                "flag_reason": NSNull(),
            ] as [String: Any]
        }
    }

    /// The fixture of `operationID` with its `data` object changed by `edit`.
    private static func editing(
        _ operationID: String,
        _ edit: (inout [String: Any]) -> Void
    ) throws -> [String: Data] {
        let fixture = try fixture(named: operationID)
        guard
            var body = try JSONSerialization.jsonObject(with: fixture) as? [String: Any],
            var data = body["data"] as? [String: Any]
        else { throw CocoaError(.coderReadCorrupt) }

        edit(&data)
        body["data"] = data
        return [operationID: try JSONSerialization.data(withJSONObject: body)]
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
        var sent: Data?
        if let body { sent = try await Data(collecting: body, upTo: 1 << 20) }
        onRequest(operationID, request.headerFields, sent)
        await hold(operationID)
        if isOffline() || unreachable.contains(operationID) { throw URLError(.notConnectedToInternet) }

        onSend(operationID, sent)

        if let code = pickStatus(operationID) ?? statuses[operationID] {
            let status = HTTPResponse.Status(code: code)
            guard let data = answer(operationID) ?? replacements[operationID] else {
                return (HTTPResponse(status: status), nil)
            }
            return (HTTPResponse(status: status, headerFields: [.contentType: "application/json"]), HTTPBody(data))
        }

        let status = Self.status(of: operationID)
        guard status != .noContent else { return (HTTPResponse(status: status), nil) }

        let data = try answer(operationID) ?? replacements[operationID] ?? Self.fixture(named: operationID)
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
