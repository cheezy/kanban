import Foundation
import Observation
import StrideKit

/// What the Review tab's queue shows: the person's pending reviews, in the
/// server's order. It asks the API, keeps each answer in the cache, shows the
/// cached queue with its fetch time while offline, and asks again each time
/// the `me:inbox` channel says what waits on the person has changed, so a
/// review decided elsewhere leaves the queue.
@MainActor
@Observable
final class ReviewQueueModel {
    typealias Queue = [Components.Schemas.DecisionItem]

    private(set) var rows: [ReviewQueueRow] = []
    /// When the shown queue was fetched, for the offline banner.
    private(set) var fetchedAt: Date?
    private(set) var isOnline = true
    /// The last request failed, so what shows may be out of date.
    private(set) var lastLoadFailed = false
    private(set) var hasAnswer = false

    @ObservationIgnored private let api: (any StrideAPI)?
    @ObservationIgnored private let cache: Cache?
    @ObservationIgnored private let live: (any LiveUpdating)?
    @ObservationIgnored private let connectivity: Connectivity
    @ObservationIgnored private let now: @Sendable () -> Date

    /// Numbers each request, so an answer that set out before the one shown
    /// never replaces it, whichever arrives first.
    @ObservationIgnored private var requests = 0
    @ObservationIgnored private var shownRequest = 0
    /// Bumped by `forget()`, so an answer that set out before it is dropped.
    @ObservationIgnored private var session = 0

    init(
        api: (any StrideAPI)?,
        cache: Cache? = nil,
        live: (any LiveUpdating)? = nil,
        connectivity: Connectivity = .system,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.api = api
        self.cache = cache
        self.live = live
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

    var state: ReviewQueueState {
        if !rows.isEmpty { return .rows }
        if !hasAnswer { return isOffline ? .nothingSaved : .loading }
        return .empty
    }

    // MARK: Loading

    /// Asks the server for the queue, and keeps it. When the request fails,
    /// the queue shown stays, or the cached one shows if nothing does yet.
    func load() async {
        requests += 1
        let request = requests
        let asked = session
        guard let api else {
            hasAnswer = true
            return
        }

        let epoch = await cache?.epoch
        guard let queue = await Self.fetch(using: api) else {
            await fail(asked: asked, request: request)
            return
        }
        guard asked == session, request > shownRequest else { return }

        show(queue, request: request, fetchedAt: now())
        await keep(queue, since: epoch)
    }

    /// Follows the live inbox and the connection until the caller stops.
    func observe() async {
        await withDiscardingTaskGroup { group in
            group.addTask { await self.followLive() }
            group.addTask { await self.followConnectivity() }
        }
    }

    /// Drops everything shown, for a sign-out.
    func forget() {
        session += 1
        shownRequest = requests
        rows = []
        fetchedAt = nil
        lastLoadFailed = false
        hasAnswer = false
    }

    // MARK: Following

    /// Asks for the queue again after each inbox update until a sign-out. The
    /// inbox carries every kind of decision and at most 100, so the queue is
    /// read from its own route rather than taken from the update. Internal
    /// for tests.
    func followLive() async {
        guard let live else { return }

        let asked = session
        for await update in await live.updates(of: .inbox) {
            guard asked == session else { return }
            guard case .decisions = update else { continue }

            await load()
        }
    }

    private func followConnectivity() async {
        for await state in connectivity.states() {
            let cameBack = !isOnline && state == .online
            isOnline = state == .online
            if cameBack { await load() }
        }
    }

    // MARK: Helpers

    private func show(_ queue: Queue, request: Int, fetchedAt: Date) {
        shownRequest = request
        rows = queue.compactMap(ReviewQueueRow.init)
        self.fetchedAt = fetchedAt
        lastLoadFailed = false
        hasAnswer = true
    }

    /// A failure after a newer answer showed says nothing about the queue shown.
    private func fail(asked: Int, request: Int) async {
        guard asked == session, request > shownRequest else { return }

        lastLoadFailed = true
        guard !hasAnswer, let cached = try? await cache?.cached(.reviewQueue) else { return }
        guard asked == session, request > shownRequest, !hasAnswer else { return }

        show(cached.value, request: request, fetchedAt: cached.fetchedAt)
        lastLoadFailed = true
    }

    /// Saves the queue for offline use. A queue that set out before a sign-out
    /// is refused, and a cache that cannot be written only costs the offline copy.
    private func keep(_ queue: Queue, since epoch: Cache.Epoch?) async {
        guard let cache, let epoch else { return }

        _ = try? await cache.store(queue, for: .reviewQueue, since: epoch)
    }

    private nonisolated static func fetch(using api: any StrideAPI) async -> Queue? {
        guard
            case .ok(let response) = try? await api.listMyReviews(),
            let queue = try? response.body.json.data
        else { return nil }

        return queue
    }
}
