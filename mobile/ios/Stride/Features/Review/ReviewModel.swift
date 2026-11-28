import Foundation
import Observation
import StrideKit

/// What the review screen shows of one pending review. It asks the API,
/// keeps each answer in the cache, which holds the last 20 reviews opened,
/// and shows the cached review with its fetch time while offline. A decision
/// the server refuses with an HTTP 409 shows as Already decided or
/// Resubmitted. Approve signs a one-time challenge after Face ID
/// (`ApproveFlow`), and says when it went through and what can start.
/// Request changes sends the reviewer's notes from a sheet
/// (`RequestChangesFlow`), and says the task waits for the agent.
@MainActor
@Observable
final class ReviewModel {
    let taskID: Int

    private(set) var content: ReviewContent?
    /// When the shown review was fetched, for the offline banner.
    private(set) var fetchedAt: Date?
    private(set) var isOnline = true
    /// The last request failed, so what shows may be out of date.
    private(set) var lastLoadFailed = false
    /// The server says this review no longer waits on the person.
    private(set) var isUnavailable = false
    /// The review changed since it loaded.
    private(set) var conflict: ReviewConflictState?
    /// An approval is on its way.
    private(set) var isApproving = false
    /// Approved here: the tasks the review held up, which can start now.
    private(set) var approved: [String]?
    /// Why the last approval did not go through.
    private(set) var approveProblem: ApproveProblem?
    /// A request for changes is on its way.
    private(set) var isRequestingChanges = false
    /// Changes were requested here, and the task waits for the agent.
    private(set) var changesRequested = false
    /// The open Request changes sheet.
    var changesSheet: RequestChangesModel?

    @ObservationIgnored private let api: (any StrideAPI)?
    @ObservationIgnored private let cache: Cache?
    @ObservationIgnored private let connectivity: Connectivity
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Nil where the device cannot approve, as in a build without a signer.
    @ObservationIgnored private let approvals: ApproveFlow?
    @ObservationIgnored private let changes: RequestChangesFlow?

    /// Numbers each request, so an answer that set out before the one shown
    /// never replaces it, whichever arrives first.
    @ObservationIgnored private var requests = 0
    @ObservationIgnored private var shownRequest = 0

    init(
        taskID: Int,
        api: (any StrideAPI)?,
        cache: Cache? = nil,
        connectivity: Connectivity = .system,
        now: @escaping @Sendable () -> Date = { .now },
        approvals: ApproveFlow? = nil,
        changes: RequestChangesFlow? = nil
    ) {
        self.taskID = taskID
        self.api = api
        self.cache = cache
        self.connectivity = connectivity
        self.now = now
        self.approvals = approvals
        // Any build with an API can request changes: no key is needed.
        self.changes = changes ?? api.map { RequestChangesFlow(api: $0) }
    }

    // MARK: What the screen shows

    /// Offline, or the server could not be reached.
    var isOffline: Bool { !isOnline || lastLoadFailed }

    var offlineBanner: OfflineBannerContent? {
        guard isOffline, let fetchedAt else { return nil }

        return OfflineBannerContent(fetchedAt: fetchedAt)
    }

    var state: ReviewScreenState {
        if isUnavailable { return .unavailable }
        if content != nil { return .review }
        return isOffline ? .nothingSaved : .loading
    }

    /// Approving and requesting changes need the server.
    var canAct: Bool { !isOffline && conflict == nil && content != nil }

    /// Approve sends a signed approval: never offline, so an approval is never
    /// sent late, never twice at once and never after it went through.
    var canApprove: Bool {
        canAct && approvals != nil && content?.approvableHere == true && !isBusy && !isDecided
    }

    /// Request changes opens its sheet while the device is online, nothing is
    /// on its way and the review is not decided here.
    var canRequestChanges: Bool { canAct && changes != nil && !isBusy && !isDecided }

    /// Approved or changes requested here.
    var isDecided: Bool { approved != nil || changesRequested }

    /// A decision is on its way.
    private var isBusy: Bool { isApproving || isRequestingChanges }

    /// "Approved. W2702 and W2703 can start.", the identifiers as the locale
    /// lists them, or "Approved." when the review held nothing up; nil until
    /// approved.
    func approvedMessage(in locale: Locale) -> LocalizedStringResource? {
        guard let approved else { return nil }
        guard !approved.isEmpty else { return .reviewApproved }

        return .reviewApprovedCanStart(identifiers: approved.formatted(.list(type: .and).locale(locale)))
    }

    /// "Changes requested. W2701 is waiting for Claude to pick up the
    /// changes." (decision 10), or "the agent" when the review names none; nil
    /// until changes are requested.
    var changesRequestedMessage: LocalizedStringResource? {
        guard changesRequested, let content else { return nil }
        guard let agent = content.agent?.name else {
            return .reviewChangesSentNoAgent(identifier: content.identifier)
        }

        return .reviewChangesSent(identifier: content.identifier, agent: agent)
    }

    /// A problem or a decision's toast shows above the buttons, which then
    /// need a gap below it.
    var showsDecisionNotice: Bool { approveProblem != nil || isDecided }

    // MARK: Loading

    /// Asks the server for the review, and keeps it. When the request fails,
    /// the review shown stays, or the cached one shows if nothing does yet.
    /// Once decided here it asks nothing more, and an answer already on its
    /// way is dropped: the server no longer has the review waiting, so a
    /// refresh or a reconnect would replace the toast and Next with "gone", or
    /// cache the review again.
    func load() async {
        guard !isDecided else { return }
        requests += 1
        let request = requests
        guard let api else { return }

        let epoch = await cache?.epoch
        let answer = await Self.fetch(taskID, using: api)
        guard request > shownRequest else { return }

        switch answer {
        case .review(let detail):
            shownRequest = request
            show(detail, fetchedAt: now())
            await keep(detail, since: epoch)
        case .gone:
            shownRequest = request
            isUnavailable = true
            lastLoadFailed = false
        case .failed:
            await fail(request: request)
        }
    }

    /// Follows the connection until the caller stops, asking again when it
    /// comes back so a review that changed while offline shows its new state.
    func observe() async {
        for await state in connectivity.states() {
            let cameBack = !isOnline && state == .online
            isOnline = state == .online
            if cameBack { await load() }
        }
    }

    /// Shows the server's 409: the review was decided or resubmitted since it
    /// loaded. Approve and Request changes call this.
    func show(_ conflict: Components.Schemas.ReviewConflict) {
        self.conflict = ReviewConflictState(conflict)
    }

    /// Approves the review shown: a challenge, Face ID and the approval. `web`
    /// opens the sign-in a new approval key needs. A 409 shows as Already
    /// decided or Resubmitted, a 404 as gone, and a change found too large is
    /// loaded again to say where to approve it.
    func approve(web: any WebAuthenticating) async {
        guard canApprove, let content, let approvals else { return }

        isApproving = true
        approveProblem = nil
        defer { isApproving = false }
        let reason = String(localized: .reviewApproveReason(identifier: content.identifier))

        switch await approvals.approve(content, reason: reason, web: web) {
        case .approved(let holdsUp):
            approved = holdsUp
            await settle()
        case .cancelled:
            break
        case .conflict(let conflict):
            show(conflict)
        case .gone:
            isUnavailable = true
        case .tooLarge:
            await reload()
        case .problem(let problem):
            approveProblem = problem
        }
    }

    /// Opens the Request changes sheet for the review shown.
    func openRequestChanges() {
        guard canRequestChanges, let content else { return }

        approveProblem = nil
        changesSheet = RequestChangesModel(
            content: content,
            isOffline: { [weak self] in self?.isOffline ?? true },
            send: { [weak self] notes in
                // A model gone with its screen sends nothing. Never write
                // `self?.requestChanges(notes:) ?? .failed`: the optional
                // chain flattens, so a send that went through (nil) would
                // read as failed.
                guard let self else { return .failed }
                return await self.requestChanges(notes: notes)
            }
        )
    }

    /// Sends the sheet's notes, and closes it once they went through, the
    /// review was decided elsewhere (Already decided or Resubmitted) or it
    /// left the person's queue. A problem stays in the sheet with the notes.
    func requestChanges(notes: String) async -> RequestChangesProblem? {
        guard canRequestChanges, let content, let changes else { return .failed }

        isRequestingChanges = true
        defer { isRequestingChanges = false }

        switch await changes.send(notes, for: content) {
        case .sent:
            changesRequested = true
            changesSheet = nil
            await settle()
        case .conflict(let conflict):
            show(conflict)
            changesSheet = nil
        case .gone:
            isUnavailable = true
            changesSheet = nil
        case .problem(let problem):
            return problem
        }
        return nil
    }

    /// Closes the problem notice.
    func dismissApproveProblem() {
        approveProblem = nil
    }

    /// Loads the new version after a resubmission.
    func reload() async {
        conflict = nil
        approveProblem = nil
        await load()
    }

    // MARK: Helpers

    /// After a decision here: a load already on its way set out before it, so
    /// its answer, a 404 or the review as it was, must not land, and the
    /// cached review is dropped so it never reopens offline as still waiting.
    private func settle() async {
        shownRequest = requests
        try? await cache?.forget(.review(taskID: taskID))
    }

    private func show(_ detail: Components.Schemas.ReviewDetail, fetchedAt: Date) {
        content = ReviewContent(detail)
        self.fetchedAt = fetchedAt
        lastLoadFailed = false
        isUnavailable = false
    }

    /// A failure says nothing about a review already shown.
    private func fail(request: Int) async {
        lastLoadFailed = true
        guard content == nil, let cached = try? await cache?.cached(.review(taskID: taskID)) else { return }
        guard request > shownRequest, content == nil else { return }

        shownRequest = request
        show(cached.value, fetchedAt: cached.fetchedAt)
        lastLoadFailed = true
    }

    /// Saves the review for offline use. One that set out before a sign-out
    /// is refused, and a cache that cannot be written only costs the copy.
    private func keep(_ detail: Components.Schemas.ReviewDetail, since epoch: Cache.Epoch?) async {
        guard let cache, let epoch else { return }

        _ = try? await cache.store(detail, for: .review(taskID: taskID), since: epoch)
    }

    private enum Answer: Sendable {
        case review(Components.Schemas.ReviewDetail)
        /// 404: not waiting in Review, or not the person's to decide.
        case gone
        case failed
    }

    private nonisolated static func fetch(_ taskID: Int, using api: any StrideAPI) async -> Answer {
        switch try? await api.getMyReview(path: .init(taskId: taskID)) {
        case .ok(let response):
            guard let detail = try? response.body.json.data else { return .failed }
            return .review(detail)
        case .notFound:
            return .gone
        default:
            return .failed
        }
    }
}
