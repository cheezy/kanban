import Foundation
import Observation
import StrideKit

/// What the Now screen shows: the decisions waiting on the person, in the
/// server's order, with the counts above them. It asks the API, keeps each
/// answer in the cache, shows the cached list with its fetch time while
/// offline, and replaces the list with each state the `me:inbox` channel sends.
@MainActor
@Observable
final class NowModel {
    typealias List = Components.Schemas.DecisionList

    /// Every card the server sent whose kind this build knows.
    private(set) var cards: [NowCard] = []
    private(set) var summary = NowSummary()
    var filter = NowFilter.all

    /// When the shown list was fetched, for the offline banner.
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

    /// Bumped by every list shown, so an answer that set out before a newer
    /// list arrived does not replace it.
    @ObservationIgnored private var version = 0
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

    var visibleCards: [NowCard] {
        cards.filter { filter.includes($0.kind) }
    }

    func count(for filter: NowFilter) -> Int {
        cards.count(where: { filter.includes($0.kind) })
    }

    /// Offline, or the server could not be reached, so actions wait.
    var isOffline: Bool { !isOnline || lastLoadFailed }

    var offlineBanner: OfflineBannerContent? {
        guard isOffline, let fetchedAt else { return nil }

        return OfflineBannerContent(fetchedAt: fetchedAt)
    }

    var state: NowState {
        if !cards.isEmpty { return .cards }
        if !hasAnswer { return isOffline ? .nothingSaved : .loading }
        return .empty
    }

    // MARK: Loading

    /// Asks the server for the list, and keeps it. When the request fails, the
    /// list shown stays, or the cached one shows if nothing does yet.
    func load() async {
        let asked = session
        let started = version
        guard let api else {
            hasAnswer = true
            return
        }

        let epoch = await cache?.epoch
        guard let list = await Self.fetch(using: api) else {
            await fail(asked: asked, started: started)
            return
        }
        guard asked == session, started == version else { return }

        show(list, fetchedAt: now())
        await keep(list, since: epoch)
    }

    /// Follows the live list and the connection until the caller stops.
    func observe() async {
        await withDiscardingTaskGroup { group in
            group.addTask { await self.followLive() }
            group.addTask { await self.followConnectivity() }
        }
    }

    /// Drops everything shown, for a sign-out.
    func forget() {
        session += 1
        version += 1
        cards = []
        summary = NowSummary()
        filter = .all
        fetchedAt = nil
        lastLoadFailed = false
        hasAnswer = false
    }

    /// Takes a card off the list at once, after the person moved its task.
    /// An answer that set out before is dropped, since it may still hold the
    /// card; the next list from the channel or a refresh brings the counts.
    func remove(cardID: NowCard.ID) {
        version += 1
        cards.removeAll { $0.id == cardID }
    }

    // MARK: Following

    /// Shows each live list until a sign-out. The session and the cache's
    /// epoch are read before any update arrives, so an update the channel
    /// buffered for the person who signed out is neither shown nor kept, and
    /// the shell starts a new follow for the next sign-in. Internal for tests.
    func followLive() async {
        guard let live else { return }

        let asked = session
        let epoch = await cache?.epoch
        for await update in await live.updates(of: .inbox) {
            guard asked == session else { return }
            guard case .decisions(let list) = update else { continue }

            show(list, fetchedAt: now())
            await keep(list, since: epoch)
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

    private func show(_ list: List, fetchedAt: Date) {
        version += 1
        cards = list.items.compactMap(NowCard.init)
        summary = NowSummary(list.summary)
        self.fetchedAt = fetchedAt
        lastLoadFailed = false
        hasAnswer = true
    }

    private func fail(asked: Int, started: Int) async {
        guard asked == session else { return }

        lastLoadFailed = true
        guard !hasAnswer, let cached = try? await cache?.cached(.decisions) else { return }
        guard asked == session, started == version else { return }

        show(cached.value, fetchedAt: cached.fetchedAt)
        lastLoadFailed = true
    }

    /// Saves the list for offline use. A list that set out before a sign-out
    /// is refused, and a cache that cannot be written only costs the offline copy.
    private func keep(_ list: List, since epoch: Cache.Epoch?) async {
        guard let cache, let epoch else { return }

        _ = try? await cache.store(list, for: .decisions, since: epoch)
    }

    private nonisolated static func fetch(using api: any StrideAPI) async -> List? {
        guard
            case .ok(let response) = try? await api.listMyDecisions(),
            let list = try? response.body.json.data
        else { return nil }

        return list
    }
}
