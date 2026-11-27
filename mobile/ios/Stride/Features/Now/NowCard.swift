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

    /// Where an action goes, or nil when the item lacks what it needs.
    func destination(for action: NowAction) -> NowDestination? {
        switch action {
        case .openReview: taskID.map { .push(.review($0)) }
        // Replying and moving a task are on its own screen.
        case .reply, .moveToBacklog: identifier.map { .push(.task($0)) }
        case .viewAttempt: identifier.map { .push(.goal($0)) }
        case .openOnWeb: webURL.map { .web($0) }
        case .openBacklog: .show(.board(String(boardID)), on: .boards)
        }
    }

    /// The buttons below the card: every action it can follow, except opening
    /// the backlog, which is the whole Ready card.
    var buttons: [NowAction] {
        actions.filter { $0 != .openBacklog && destination(for: $0) != nil }
    }

    private var identifier: String? {
        content.identifier.isEmpty ? nil : content.identifier
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

        let style = Duration.UnitsFormatStyle(
            allowedUnits: [.hours, .minutes, .seconds],
            width: .narrow,
            maximumUnitCount: 2
        )
        return .nowHookFailedExit(code: String(exitCode), duration: duration.formatted(style.locale(locale)))
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

    private static func verdicts(_ verdicts: [Components.Schemas.DecisionVerdict]) -> [Verdict] {
        verdicts.compactMap { verdict in
            let name = verdict.section.value1?.rawValue ?? verdict.section.value2
            guard let section = name.flatMap(VerdictSection.init(rawValue:)) else { return nil }

            let status = verdict.status.flatMap { $0.value1?.rawValue ?? $0.value2 }
            return Verdict(section: section, state: VerdictState(apiValue: status))
        }
    }

    private static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme == "https", url.host() != nil else { return nil }

        return url
    }
}
