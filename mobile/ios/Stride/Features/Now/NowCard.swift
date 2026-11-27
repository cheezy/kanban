import Foundation
import StrideKit

/// One decision on the Now screen, made from the server's item: the shared
/// card's content, what the card adds for its kind, and the actions it offers.
struct NowCard: Identifiable, Hashable, Sendable {
    typealias Item = Components.Schemas.DecisionItem

    let id: String
    let content: DecisionCardContent
    let detail: NowCardDetail
    /// The actions the server offers that a card shows, in the server's order.
    let actions: [NowAction]
    let taskID: Int?
    let boardID: Int
    /// The item's web page, only when it is an https address.
    let webURL: URL?

    var kind: DecisionKind { content.kind }

    /// Nil for a kind this build does not know, which the screen skips.
    init?(_ item: Item) {
        guard let kind = item.kind.value1.flatMap({ DecisionKind(rawValue: $0.rawValue) }) else { return nil }

        let summary = item.summary
        let agent = summary.agent.map { AgentAvatarContent(name: $0) }
        let detail = Self.detail(of: item, kind: kind, agent: agent)
        let review = kind == .review ? item.details.value1 : nil

        id = item.id
        content = DecisionCardContent(
            kind: kind,
            identifier: summary.identifier ?? "",
            title: summary.title ?? "",
            priority: summary.priority?.value1.flatMap { Priority(rawValue: $0.rawValue) },
            holdsUp: item.holdsUp ?? 0,
            // A review names its agent on its own row; the other kinds say it
            // in their own sentence or quote.
            agent: kind == .review ? agent : nil,
            issue: review?.firstFailedNote,
            verdicts: review.map { Self.verdicts($0.verdicts) } ?? [],
            since: item.since
        )
        self.detail = detail
        actions = item.actions.compactMap(NowAction.init)
        taskID = item.taskId
        boardID = item.boardId
        webURL = Self.webURL(item.webUrl)
    }

    // MARK: Actions

    /// Whether the card has what `action` needs: a task id for the actions
    /// that change or open the task, a Stride page for the web.
    func canPerform(_ action: NowAction) -> Bool {
        switch action {
        case .openReview, .reply, .moveToBacklog, .viewAttempt: taskID != nil
        case .openOnWeb: webURL != nil
        case .openBacklog: true
        }
    }

    /// Where an action goes, or nil when it stays on the Now screen (a reply,
    /// a move or the attempt, which `NowActions` follows) or the item lacks
    /// what it needs.
    func destination(for action: NowAction) -> NowDestination? {
        switch action {
        case .openReview: taskID.map { .push(.review($0)) }
        case .openOnWeb: webURL.map { .web($0) }
        case .openBacklog: .show(.board(String(boardID), column: .backlog), on: .boards)
        case .reply, .moveToBacklog, .viewAttempt: nil
        }
    }

    /// The buttons below the card: the actions section 6.3 of the design gives
    /// its kind, in the server's order, that it can follow. A Released card
    /// has Reply and Move to Backlog only, and the Ready card none, since the
    /// whole card opens the backlog, whatever else the server sends.
    var buttons: [NowAction] {
        let allowed = Self.buttons(for: kind)
        return actions.filter { allowed.contains($0) && canPerform($0) }
    }

    private static func buttons(for kind: DecisionKind) -> Set<NowAction> {
        switch kind {
        case .review: [.openReview, .openOnWeb]
        case .released: [.reply, .moveToBacklog]
        case .claimExpired: [.moveToBacklog, .openOnWeb]
        case .hookFailed: [.viewAttempt, .openOnWeb]
        case .readyEmpty: []
        }
    }

    // MARK: Text

    /// The sentence or quote the card shows for its kind, in `locale`.
    func body(in locale: Locale) -> String? {
        switch detail {
        case .review:
            nil
        case .released(let reason, _):
            reason.map { LocalizedStringResource.nowReleasedReason(reason: $0).resolved(in: locale) }
        case .claimExpired(let agent, let minutes):
            claimExpiredBody(agent: agent, minutes: minutes).resolved(in: locale)
        case .hookFailed(let exitCode, let duration):
            hookFailedBody(exitCode: exitCode, duration: duration, locale: locale).resolved(in: locale)
        case .readyEmpty(_, let idle, let backlog):
            [LocalizedStringResource.nowIdleAgents(count: idle), .nowBacklogTasks(count: backlog)]
                .map { $0.resolved(in: locale) }
                .joined(separator: " ")
        }
    }

    /// The Ready card's heading, which names the board.
    func readyHeading(in locale: Locale) -> String? {
        guard case .readyEmpty(let board, _, _) = detail else { return nil }

        return LocalizedStringResource.nowReadyEmptyBoard(board: board).resolved(in: locale)
    }

    private func claimExpiredBody(agent: String?, minutes: Int?) -> LocalizedStringResource {
        guard let agent, let minutes else { return .nowClaimExpired }

        return .nowClaimExpiredAgent(agent: agent, count: minutes)
    }

    private func hookFailedBody(exitCode: Int?, duration: Duration?, locale: Locale) -> LocalizedStringResource {
        guard let exitCode, let duration else { return .nowHookFailed }

        return .nowHookFailedExit(code: String(exitCode), duration: duration.hookText(in: locale))
    }

    // MARK: Reading the item

    private static func detail(of item: Item, kind: DecisionKind, agent: AgentAvatarContent?) -> NowCardDetail {
        // The details are one of five shapes, and fields that may be null let
        // more than one decode, so the kind picks which to read.
        let details = item.details
        switch kind {
        case .review:
            return .review
        case .released:
            return .released(reason: details.value2?.reason, agent: agent)
        case .claimExpired:
            return .claimExpired(agent: item.summary.agent, minutes: details.value3.flatMap(minutes))
        case .hookFailed:
            let hook = details.value4
            return .hookFailed(exitCode: hook?.exitCode, duration: hook?.durationMs.map { .milliseconds($0) })
        case .readyEmpty:
            let ready = details.value5
            return .readyEmpty(
                board: item.summary.board.name,
                idleAgents: max(0, ready?.idleAgents ?? 0),
                backlogCount: max(0, ready?.backlogCount ?? 0)
            )
        }
    }

    private static func minutes(_ claim: Components.Schemas.DecisionClaimExpiredDetails) -> Int? {
        guard let claimedAt = claim.claimedAt, let expiredAt = claim.expiredAt, expiredAt >= claimedAt else { return nil }

        return Int((expiredAt.timeIntervalSince(claimedAt) / 60).rounded())
    }

    /// The verdicts this build knows, in the server's order. The Review queue
    /// reads them the same way.
    static func verdicts(_ verdicts: [Components.Schemas.DecisionVerdict]) -> [Verdict] {
        verdicts.compactMap { verdict in
            let name = verdict.section.value1?.rawValue ?? verdict.section.value2
            guard let section = name.flatMap(VerdictSection.init(rawValue:)) else { return nil }

            let status = verdict.status.flatMap { $0.value1?.rawValue ?? $0.value2 }
            return Verdict(section: section, state: VerdictState(apiValue: status))
        }
    }

    /// Only a page on the Stride server opens, so an item cannot send the
    /// person to another site.
    private static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string), StrideWeb.isStridePage(url) else { return nil }

        return url
    }
}
