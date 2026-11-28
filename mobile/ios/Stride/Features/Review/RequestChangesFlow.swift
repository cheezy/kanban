import Foundation
import StrideKit

/// Sends one Request changes from the app (design section 6.7): the
/// reviewer's notes, with the `review_requested_at` the screen loaded and a
/// new idempotency key. It asks for no Face ID, since a request for changes
/// approves nothing.
///
/// A request that never reached the server is sent once more with the same
/// key and the same body (decision 18), so a lost answer cannot send the notes
/// twice or turn into Already decided. The notes go only to the review
/// endpoint, and nothing here logs them.
@MainActor
struct RequestChangesFlow {
    let api: any StrideAPI
    /// The idempotency key for each new request.
    var newKey: @Sendable () -> String = { UUID().uuidString }

    func send(_ notes: String, for content: ReviewContent) async -> RequestChangesAnswer {
        let body = Components.Schemas.RequestReviewChangesRequest(
            reviewRequestedAt: content.reviewRequestedAt,
            notes: notes
        )
        let key = newKey()
        let taskID = content.taskID
        if let answer = await Self.post(body, key: key, taskID: taskID, using: api) { return answer }
        return await Self.post(body, key: key, taskID: taskID, using: api) ?? .problem(.failed)
    }

    /// The server's answer, or nil when the request did not reach it.
    private nonisolated static func post(
        _ body: Components.Schemas.RequestReviewChangesRequest,
        key: String,
        taskID: Int,
        using api: any StrideAPI
    ) async -> RequestChangesAnswer? {
        let output: Operations.RequestMyReviewChanges.Output
        do {
            output = try await api.requestMyReviewChanges(
                path: .init(taskId: taskID),
                headers: .init(idempotencyKey: key),
                body: .json(body)
            )
        } catch {
            return CallFailure.isTransport(error) ? nil : .problem(.failed)
        }

        switch output {
        case .ok:
            return .sent
        case .conflict(let response):
            return (try? response.body.json).map(RequestChangesAnswer.conflict) ?? .problem(.failed)
        case .notFound:
            return .gone
        case .forbidden:
            return .problem(.notAllowed)
        case .unprocessableContent:
            return .problem(.refused)
        default:
            return .problem(.failed)
        }
    }
}
