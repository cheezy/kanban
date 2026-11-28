import Foundation
import os
import Testing

@testable import Stride
@testable import StrideKit

/// What the Review queue shows: the pending reviews in the server's order,
/// each one's size, what it shows offline, and how it follows the inbox.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ReviewQueueModelTests {
    private nonisolated static let fetched = Date(timeIntervalSince1970: 1_795_000_000)
    private static let fixtureIDs = ["review-4812", "review-4818", "review-4821"]

    @Test("keeps the server's order")
    func serverOrder() async throws {
        let model = ReviewQueueModel(api: FixtureAPI().client)
        #expect(model.state == .loading)

        await model.load()

        #expect(model.state == .rows)
        #expect(model.rows.map(\.id) == Self.fixtureIDs)
        let first = try #require(model.rows.first)
        #expect(first.content.identifier == "W101")
        #expect(first.content.holdsUp == 2)
        #expect(first.files == 4)
        #expect(first.sizeLabel == nil)
        #expect(first.content.verdicts.isEmpty == false)
        #expect(model.rows.map(\.taskID) == [4812, 4818, 4821])
    }

    @Test("a reordered queue is shown in its new order, not sorted again")
    func noResorting() async throws {
        let data = try DecisionFixtures.reviewsData { $0.reverse() }
        let model = ReviewQueueModel(api: FixtureAPI(replacing: [Operations.ListMyReviews.id: data]).client)

        await model.load()

        #expect(model.rows.map(\.id) == Self.fixtureIDs.reversed())
    }

    @Test("a large change is labelled, and says where to approve it when this device may not")
    func largeChangeLabelled() async throws {
        let phone = ReviewQueueModel(api: FixtureAPI().client)
        await phone.load()
        // The server offers no Approve for a large change on a phone.
        #expect(phone.rows.map(\.sizeLabel) == [nil, .tooLargeForPhone, nil])
        let phoneSecond = try #require(phone.rows.dropFirst().first)
        #expect(phoneSecond.files == 14)

        let data = try DecisionFixtures.reviewsData { items in
            items[1]["actions"] = ["open_review", "approve", "request_changes", "open_on_web"]
        }
        let tablet = ReviewQueueModel(api: FixtureAPI(replacing: [Operations.ListMyReviews.id: data]).client)
        await tablet.load()
        #expect(tablet.rows.map(\.sizeLabel) == [nil, .large, nil])

        let readOnly = try DecisionFixtures.reviewsData { items in
            items[1]["actions"] = ["open_on_web"]
        }
        let viewer = ReviewQueueModel(api: FixtureAPI(replacing: [Operations.ListMyReviews.id: readOnly]).client)
        await viewer.load()
        let viewerSecond = try #require(viewer.rows.dropFirst().first)
        #expect(viewerSecond.sizeLabel == .large)
    }

    @Test("files the server could not count show no count")
    func filesUnknown() async throws {
        let data = try DecisionFixtures.reviewsData { items in
            var details = items[0]["details"] as? [String: Any] ?? [:]
            var size = details["size"] as? [String: Any] ?? [:]
            size["files_unknown"] = true
            size["files"] = 0
            details["size"] = size
            items[0]["details"] = details
        }
        let model = ReviewQueueModel(api: FixtureAPI(replacing: [Operations.ListMyReviews.id: data]).client)

        await model.load()

        #expect(model.rows.first?.files == nil)
    }

    @Test("an item that is not a review is skipped")
    func notAReviewSkipped() async throws {
        let data = try DecisionFixtures.reviewsData { items in
            var other = items[0]
            other["id"] = "released-1"
            other["kind"] = "released"
            items.insert(other, at: 1)
        }
        let model = ReviewQueueModel(api: FixtureAPI(replacing: [Operations.ListMyReviews.id: data]).client)

        await model.load()

        #expect(model.rows.map(\.id) == Self.fixtureIDs)
    }

    @Test("empty queue shows the empty state")
    func empty() async {
        let data = Data(#"{"data": []}"#.utf8)
        let model = ReviewQueueModel(api: FixtureAPI(replacing: [Operations.ListMyReviews.id: data]).client)

        await model.load()

        #expect(model.state == .empty)
        #expect(model.rows.isEmpty)
    }

    @Test("offline reads the cached queue")
    func offlineReadsCache() async throws {
        let container = try TemporaryContainer()
        let cache = Cache(container: container.url, now: { Self.fetched })
        let online = ReviewQueueModel(api: FixtureAPI().client, cache: cache, now: { Self.fetched })
        await online.load()
        #expect(online.offlineBanner == nil)

        let unreachable = FixtureAPI(unreachable: [Operations.ListMyReviews.id]).client
        let offline = ReviewQueueModel(api: unreachable, cache: cache, now: { .now })
        await offline.load()

        #expect(offline.state == .rows)
        #expect(offline.rows.map(\.id) == Self.fixtureIDs)
        let offlineSecond = try #require(offline.rows.dropFirst().first)
        #expect(offlineSecond.sizeLabel == .tooLargeForPhone)
        #expect(offline.isOffline)
        #expect(offline.offlineBanner == OfflineBannerContent(fetchedAt: Self.fetched))
        withExtendedLifetime(container) {}
    }

    @Test("offline with nothing saved says so, rather than loading for ever")
    func nothingSaved() async {
        let model = ReviewQueueModel(api: FixtureAPI(unreachable: [Operations.ListMyReviews.id]).client)

        await model.load()

        #expect(model.state == .nothingSaved)
        #expect(model.offlineBanner == nil)
    }

    @Test("a refresh error keeps the last list")
    func refreshErrorKeeps() async {
        let isOffline = OSAllocatedUnfairLock(initialState: false)
        let model = ReviewQueueModel(
            api: FixtureAPI(isOffline: { isOffline.withLock { $0 } }).client,
            now: { Self.fetched }
        )
        await model.load()

        isOffline.withLock { $0 = true }
        await model.load()

        #expect(model.rows.map(\.id) == Self.fixtureIDs)
        #expect(model.lastLoadFailed)
        #expect(model.offlineBanner == OfflineBannerContent(fetchedAt: Self.fetched))

        isOffline.withLock { $0 = false }
        await model.load()
        #expect(model.isOffline == false)
    }

    @Test("a review decided elsewhere leaves the queue at the next inbox update")
    func decidedElsewhere() async throws {
        let decided = try DecisionFixtures.reviewsData { $0.removeFirst() }
        let isDecided = OSAllocatedUnfairLock(initialState: false)
        let api = FixtureAPI(answering: { id in
            id == Operations.ListMyReviews.id && isDecided.withLock { $0 } ? decided : nil
        })
        let live = ManualLive()
        let model = ReviewQueueModel(api: api.client, live: live, connectivity: ConnectivitySwitch(online: true).connectivity)
        await model.load()
        let observing = Task { await model.observe() }
        defer { observing.cancel() }

        isDecided.withLock { $0 = true }
        live.continuation.yield(.decisions(try await DecisionFixtures.list(DecisionFixtures.data())))
        await waitUntil { model.rows.count == 2 }

        #expect(model.rows.map(\.id) == Array(Self.fixtureIDs.dropFirst()))
    }

    @Test("an older answer that arrives after a newer one does not replace it")
    func olderAnswerDropped() async throws {
        let decided = try DecisionFixtures.reviewsData { $0.removeFirst() }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let firstAsked = OSAllocatedUnfairLock(initialState: false)
        let gate = DispatchSemaphore(value: 0)
        let api = FixtureAPI(answering: { id in
            guard id == Operations.ListMyReviews.id else { return nil }
            let call = calls.withLock { count in
                count += 1
                return count
            }
            guard call == 1 else { return decided }
            // The first request holds the full queue and is answered last.
            firstAsked.withLock { $0 = true }
            gate.wait()
            return nil
        })
        let model = ReviewQueueModel(api: api.client)

        let slow = Task { await model.load() }
        do {
            defer { gate.signal() }
            await waitUntil { firstAsked.withLock { $0 } }
            await model.load()
            #expect(model.rows.count == 2)
        }
        await slow.value

        #expect(model.rows.map(\.id) == Array(Self.fixtureIDs.dropFirst()))
    }

    @Test("an inbox update after a sign-out ends the follow without asking again")
    func liveAfterForgetEnds() async throws {
        let asked = OSAllocatedUnfairLock(initialState: 0)
        let live = ManualLive()
        let model = ReviewQueueModel(api: FixtureAPI(onSend: { id, _ in
            if id == Operations.ListMyReviews.id { asked.withLock { $0 += 1 } }
        }).client, live: live)
        let following = Task { await model.followLive() }

        // The follow is running once its first update loads the queue.
        live.continuation.yield(.decisions(try await DecisionFixtures.list(DecisionFixtures.data())))
        await waitUntil { model.rows.count == 3 }

        model.forget()
        live.continuation.yield(.decisions(try await DecisionFixtures.list(DecisionFixtures.data())))
        await following.value

        #expect(model.rows.isEmpty)
        #expect(asked.withLock { $0 } == 1)
    }

    @Test("forgetting drops everything shown, and an answer that set out before it")
    func forget() async {
        let gate = DispatchSemaphore(value: 0)
        let asking = OSAllocatedUnfairLock(initialState: 0)
        let api = FixtureAPI(answering: { id in
            // The first load answers at once; the second waits for the gate.
            if id == Operations.ListMyReviews.id, asking.withLock({ $0 += 1; return $0 }) == 2 { gate.wait() }
            return nil
        })
        let model = ReviewQueueModel(api: api.client)
        await model.load()

        model.forget()

        #expect(model.rows.isEmpty)
        #expect(model.state == .loading)
        #expect(model.fetchedAt == nil)

        // The late load has set out before the second forget.
        let late = Task { await model.load() }
        do {
            defer { gate.signal() }
            await waitUntil { asking.withLock { $0 } == 2 }
            model.forget()
        }
        await late.value
        #expect(model.rows.isEmpty)
    }
}
