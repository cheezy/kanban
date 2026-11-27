import Foundation
import Observation
import StrideKit

/// The reply sheet: a comment on a released task, sent once.
@MainActor
@Observable
final class ReplyModel {
    /// The most a comment may hold, counted in Unicode scalars, as the server
    /// counts codepoints.
    static let limit = 10_000

    let cardID: NowCard.ID
    let taskID: Int
    /// The task's identifier and title, from the card, for the sheet's heading.
    let identifier: String
    let title: String
    var text = ""
    private(set) var isSending = false
    /// Why the last send failed, shown in the sheet.
    private(set) var problem: NowNotice?

    @ObservationIgnored private let api: (any StrideAPI)?
    @ObservationIgnored private let offline: @MainActor () -> Bool

    init(
        cardID: NowCard.ID,
        taskID: Int,
        identifier: String,
        title: String,
        api: (any StrideAPI)?,
        isOffline: @escaping @MainActor () -> Bool
    ) {
        self.cardID = cardID
        self.taskID = taskID
        self.identifier = identifier
        self.title = title
        self.api = api
        offline = isOffline
    }

    var isOffline: Bool { offline() }

    var isTooLong: Bool { content.unicodeScalars.count > Self.limit }

    /// A reply needs some text, no more than the limit, and a connection, and
    /// waits while one is on its way.
    var canSend: Bool {
        !content.isEmpty && !isTooLong && !isSending && !isOffline
    }

    /// Sends the reply, and says whether the server kept it.
    func send() async -> Bool {
        guard canSend, let api else { return false }

        isSending = true
        defer { isSending = false }
        problem = nil
        let outcome = await Self.post(content, on: taskID, using: api)
        problem = outcome
        return outcome == nil
    }

    /// The text without the blank space around it.
    private var content: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Nil when the comment was added, or why it was not.
    private nonisolated static func post(_ content: String, on taskID: Int, using api: any StrideAPI) async -> NowNotice? {
        do {
            switch try await api.commentOnMyTask(path: .init(id: taskID), body: .json(.init(content: content))) {
            case .created: return nil
            case .forbidden: return .notAllowed
            case .notFound: return .taskMoved
            default: return .failed
            }
        } catch {
            return .failed
        }
    }
}
