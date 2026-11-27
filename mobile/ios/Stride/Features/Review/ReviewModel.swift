import Foundation
import Observation
import StrideKit

/// What the review screen shows of one pending review. It asks the API,
/// keeps each answer in the cache, which holds the last 20 reviews opened,
/// and shows the cached review with its fetch time while offline. A decision
/// the server refuses with an HTTP 409 shows as Already decided or
/// Resubmitted; the buttons that send one come with the next goal.
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

    @ObservationIgnored private let api: (any StrideAPI)?
    @ObservationIgnored private let cache: Cache?
    @ObservationIgnored private let connectivity: Connectivity
    @ObservationIgnored private let now: @Sendable () -> Date

    /// Numbers each request, so an answer that set out before the one shown
    /// never replaces it, whichever arrives first.
    @ObservationIgnored private var requests = 0
    @ObservationIgnored private var shownRequest = 0

    init(
        taskID: Int,
        api: (any StrideAPI)?,
        cache: Cache? = nil,
        connectivity: Connectivity = .system,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.taskID = taskID
        self.api = api
        self.cache = cache
        self.connectivity = connectivity
        self.now = now
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

    // MARK: Loading

    /// Asks the server for the review, and keeps it. When the request fails,
    /// the review shown stays, or the cached one shows if nothing does yet.
    func load() async {
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
    /// loaded. The next goal's Approve and Request changes call this.
    func show(_ conflict: Components.Schemas.ReviewConflict) {
        self.conflict = ReviewConflictState(conflict)
    }

    /// Loads the new version after a resubmission.
    func reload() async {
        conflict = nil
        await load()
    }

    // MARK: Helpers

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

/// What the review screen shows.
enum ReviewScreenState: Equatable, Sendable {
    /// The first answer is still on its way.
    case loading
    /// Offline, with nothing saved on the device to show.
    case nothingSaved
    /// The review no longer waits on the person.
    case unavailable
    case review
}
