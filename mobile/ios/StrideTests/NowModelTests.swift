import Foundation
import os
import Testing

@testable import Stride
@testable import StrideKit

/// What the Now screen shows: the decisions in the server's order, the
/// filters, the live list, and what it shows offline.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NowModelTests {
    private nonisolated static let fetched = Date(timeIntervalSince1970: 1_795_000_000)
    private static let fixtureIDs = ["review-4812", "released-9001", "claim_expired-4814", "hook_failed-4815", "ready_empty-12"]

    @Test("the cards keep the server's order, and each filter counts its kinds")
    func orderAndFilters() async {
        let model = NowModel(api: FixtureAPI().client)
        #expect(model.state == .loading)

        await model.load()

        #expect(model.state == .cards)
        #expect(model.cards.map(\.id) == Self.fixtureIDs)
        #expect(model.summary == NowSummary(waiting: 4, heldUp: 3, agentsWorking: 1))
        #expect(NowFilter.allCases.map(model.count(for:)) == [5, 1, 3, 1])

        model.filter = .problems
        #expect(model.visibleCards.map(\.id) == ["released-9001", "claim_expired-4814", "hook_failed-4815"])
        model.filter = .reviews
        #expect(model.visibleCards.map(\.id) == ["review-4812"])
        model.filter = .ready
        #expect(model.visibleCards.map(\.id) == ["ready_empty-12"])
    }

    @Test("a kind or an action this build does not know is skipped")
    func unknownSkipped() async throws {
        let data = try DecisionFixtures.data { items in
            var future = items[0]
            future["id"] = "future-1"
            future["kind"] = "a_future_kind"
            items.insert(future, at: 1)
            items[0]["actions"] = ["open_review", "a_future_action", "approve", "open_on_web"]
        }
        let model = NowModel(api: DecisionFixtures.api(data))

        await model.load()

        #expect(model.cards.map(\.id) == Self.fixtureIDs)
        // Approving and asking for changes happen on the review screen.
        #expect(model.cards.first?.actions == [.openReview, .openOnWeb])
    }

    @Test("nothing waiting shows the empty state")
    func empty() async {
        let data = Data(#"{"data": {"items": [], "summary": {"waiting": 0, "held_up": 0, "agents_working": 0}}}"#.utf8)
        let model = NowModel(api: DecisionFixtures.api(data))

        await model.load()

        #expect(model.state == .empty)
        #expect(model.summary == NowSummary())
    }

    @Test("a live list replaces the shown one, so a cleared card goes")
    func liveReplaces() async throws {
        let live = ManualLive()
        let model = NowModel(api: FixtureAPI().client, live: live, connectivity: ConnectivitySwitch(online: true).connectivity)
        await model.load()
        let observing = Task { await model.observe() }
        defer { observing.cancel() }

        let cleared = try await DecisionFixtures.list(DecisionFixtures.data { $0.removeFirst() })
        live.continuation.yield(.decisions(cleared))
        await waitUntil { model.cards.count == 4 }

        #expect(model.cards.map(\.id) == Array(Self.fixtureIDs.dropFirst()))
        #expect(model.count(for: .reviews) == 0)
    }

    @Test("a live list that lands during a reload is not replaced by the reload's older answer")
    func liveDuringReloadKept() async throws {
        let gate = DispatchSemaphore(value: 0)
        let asking = OSAllocatedUnfairLock(initialState: false)
        let api = FixtureAPI(isOffline: {
            asking.withLock { $0 = true }
            gate.wait()
            return false
        })
        let live = ManualLive()
        let model = NowModel(api: api.client, live: live, connectivity: ConnectivitySwitch(online: true).connectivity)
        let observing = Task { await model.observe() }
        defer { observing.cancel() }

        // The reload has asked; the live list arrives before its answer.
        let reload = Task { await model.load() }
        await waitUntil { asking.withLock { $0 } }
        let cleared = try await DecisionFixtures.list(DecisionFixtures.data { $0.removeFirst() })
        live.continuation.yield(.decisions(cleared))
        await waitUntil { model.cards.count == 4 }
        gate.signal()
        await reload.value

        #expect(model.cards.map(\.id) == Array(Self.fixtureIDs.dropFirst()))
    }

    @Test("offline, the cached list shows with when it was fetched, and actions wait")
    func offlineShowsCache() async throws {
        let container = try TemporaryContainer()
        let cache = Cache(container: container.url, now: { Self.fetched })
        let online = NowModel(api: FixtureAPI().client, cache: cache, now: { Self.fetched })
        await online.load()
        #expect(online.offlineBanner == nil)
        #expect(online.isOffline == false)

        let unreachable = FixtureAPI(unreachable: [Operations.ListMyDecisions.id]).client
        let offline = NowModel(api: unreachable, cache: cache, now: { .now })
        await offline.load()

        #expect(offline.cards.map(\.id) == Self.fixtureIDs)
        #expect(offline.isOffline)
        #expect(offline.offlineBanner == OfflineBannerContent(fetchedAt: Self.fetched))
        withExtendedLifetime(container) {}
    }

    @Test("a failed reload keeps the cards shown and marks them offline")
    func failedReloadKeeps() async {
        let isOffline = OSAllocatedUnfairLock(initialState: false)
        let model = NowModel(api: FixtureAPI(isOffline: { isOffline.withLock { $0 } }).client, now: { Self.fetched })
        await model.load()

        isOffline.withLock { $0 = true }
        await model.load()

        #expect(model.cards.count == 5)
        #expect(model.offlineBanner == OfflineBannerContent(fetchedAt: Self.fetched))

        isOffline.withLock { $0 = false }
        await model.load()
        #expect(model.isOffline == false)
    }

    @Test("offline with nothing saved says so, rather than loading for ever")
    func nothingSaved() async {
        let model = NowModel(api: FixtureAPI(unreachable: [Operations.ListMyDecisions.id]).client)

        await model.load()

        #expect(model.state == .nothingSaved)
        #expect(model.offlineBanner == nil)
    }

    @Test("losing the connection disables actions, and coming back reloads")
    func connectivityFollowed() async throws {
        let connection = ConnectivitySwitch(online: true)
        let isOffline = OSAllocatedUnfairLock(initialState: false)
        let data = try DecisionFixtures.data()
        let model = NowModel(
            api: FixtureAPI(replacing: [Operations.ListMyDecisions.id: data], isOffline: { isOffline.withLock { $0 } }).client,
            connectivity: connection.connectivity
        )
        await model.load()
        let observing = Task { await model.observe() }
        defer { observing.cancel() }
        await waitUntil { connection.isListening }
        #expect(model.isOnline)

        isOffline.withLock { $0 = true }
        connection.set(online: false)
        await waitUntil { !model.isOnline }
        #expect(model.isOffline)
        // A pull to refresh while offline fails, and the cards stay.
        await model.load()
        #expect(model.lastLoadFailed)
        #expect(model.cards.count == 5)

        // Coming back reloads by itself, so the failed load is forgotten.
        isOffline.withLock { $0 = false }
        connection.set(online: true)
        await waitUntil { !model.isOffline }
        #expect(model.isOnline)
        #expect(model.lastLoadFailed == false)
    }

    @Test("a live list that arrives after a sign-out is neither shown nor kept, and the follow ends")
    func liveAfterForgetDropped() async throws {
        let container = try TemporaryContainer()
        let cache = Cache(container: container.url, now: { Self.fetched })
        let live = ManualLive()
        let model = NowModel(api: FixtureAPI().client, cache: cache, live: live, now: { Self.fetched })
        let following = Task { await model.followLive() }

        // The follow is running once its first list shows.
        live.continuation.yield(.decisions(try await DecisionFixtures.list(DecisionFixtures.data())))
        await waitUntil { model.cards.count == 5 }

        model.forget()
        try await cache.wipe()
        live.continuation.yield(.decisions(try await DecisionFixtures.list(DecisionFixtures.data())))
        await following.value

        #expect(model.cards.isEmpty)
        #expect(model.state == .loading)
        #expect(try await cache.cached(.decisions) == nil)
        withExtendedLifetime(container) {}
    }

    @Test("forgetting drops everything shown, and an answer that set out before it")
    func forget() async {
        let model = NowModel(api: FixtureAPI().client)
        await model.load()
        model.filter = .ready

        model.forget()

        #expect(model.cards.isEmpty)
        #expect(model.summary == NowSummary())
        #expect(model.filter == .all)
        #expect(model.state == .loading)

        let late = Task { await model.load() }
        await Task.yield()
        model.forget()
        await late.value
        #expect(model.cards.isEmpty)
    }
}
