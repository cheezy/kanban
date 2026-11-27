import Foundation
import Observation
import StrideKit

/// Follows a Now card's buttons. Opening a review, the web page or the
/// backlog goes to the router; moving a task to Backlog, replying and viewing
/// a hook's attempt happen here, on the Now screen. Every action waits while
/// the device is offline.
@MainActor
@Observable
final class NowActions {
    /// The cards whose move to Backlog is on its way, so a second tap waits.
    private(set) var moving: Set<NowCard.ID> = []
    /// What the last action came to, until the person closes it.
    var notice: NowNotice?
    var sheet: NowSheet?

    @ObservationIgnored private let api: (any StrideAPI)?
    @ObservationIgnored private let now: NowModel
    /// Bumped by `forget()`, so an answer that set out before it is dropped.
    @ObservationIgnored private var session = 0

    init(api: (any StrideAPI)?, now: NowModel) {
        self.api = api
        self.now = now
    }

    var isOffline: Bool { now.isOffline }

    func isMoving(_ card: NowCard) -> Bool {
        moving.contains(card.id)
    }

    /// Follows `action` on `card`. Returns where it goes when that is another
    /// screen or a web page, for the caller to open, and nil when it acts
    /// here or cannot act: offline, or the card lacks what it needs.
    func perform(_ action: NowAction, on card: NowCard) -> NowDestination? {
        guard !isOffline, card.canPerform(action) else { return nil }

        switch action {
        case .openReview, .openOnWeb, .openBacklog:
            return card.destination(for: action)
        case .reply:
            reply(to: card)
        case .viewAttempt:
            viewAttempt(of: card)
        case .moveToBacklog:
            Task { await moveToBacklog(card) }
        }
        return nil
    }

    /// Moves the card's task to Backlog. The card leaves the list when the
    /// server moved it; when the task moved first, the list is fetched again.
    func moveToBacklog(_ card: NowCard) async {
        guard let api, let taskID = card.taskID, !isOffline, !moving.contains(card.id) else { return }

        let asked = session
        moving.insert(card.id)
        let outcome = await Self.move(taskID, using: api)
        guard asked == session else { return }

        moving.remove(card.id)
        switch outcome {
        case nil:
            now.remove(cardID: card.id)
            notice = .movedToBacklog
        case .taskMoved:
            notice = .taskMoved
            await now.load()
        case let problem?:
            notice = problem
        }
    }

    /// Sends the open reply, and closes its sheet when the server kept it.
    func send(_ reply: ReplyModel) async {
        let asked = session
        guard await reply.send(), asked == session else { return }

        if case .reply(let open) = sheet, open === reply { sheet = nil }
        notice = .replySent
    }

    /// Drops every sheet, notice and move on its way, for a sign-out.
    func forget() {
        session += 1
        moving = []
        notice = nil
        sheet = nil
    }

    // MARK: Helpers

    private func reply(to card: NowCard) {
        guard let taskID = card.taskID else { return }

        sheet = .reply(ReplyModel(
            cardID: card.id,
            taskID: taskID,
            identifier: card.content.identifier,
            title: card.content.title,
            api: api,
            isOffline: { [now] in now.isOffline }
        ))
    }

    /// A failed hook's card carries its goal's id as the task id.
    private func viewAttempt(of card: NowCard) {
        guard let goalID = card.taskID else { return }

        sheet = .attempt(HookAttemptModel(cardID: card.id, goalID: goalID, identifier: card.content.identifier, api: api))
    }

    /// Nil when the task moved to Backlog, or why it did not.
    private nonisolated static func move(_ taskID: Int, using api: any StrideAPI) async -> NowNotice? {
        do {
            switch try await api.moveMyTaskToBacklog(path: .init(id: taskID)) {
            case .ok: return nil
            // Another person or agent moved it first, or it is gone.
            case .conflict, .notFound: return .taskMoved
            case .forbidden: return .notAllowed
            case .unprocessableContent(let refusal):
                let reason = try? refusal.body.json.error.value1
                return reason == .notMovable ? .taskMoved : .failed
            default: return .failed
            }
        } catch {
            return .failed
        }
    }
}
