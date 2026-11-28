import Foundation
import Testing

@testable import StrideKit

@Suite(.timeLimit(.minutes(1)))
struct LiveChannelTests {
    private let server = FakeLiveServer()

    // MARK: Joining and updates

    @Test("joins me:inbox and delivers updates")
    func joinsInbox() async throws {
        let live = server.channel()
        var updates = await live.updates(of: .inbox).makeAsyncIterator()

        let connection = try await server.connection(1)
        #expect(connection.token == "EXAMPLE-socket-1")
        connection.send(.opened)
        await eventually("it joins") { connection.actions == [.join(.inbox)] }
        connection.send(.joined(.inbox))
        try connection.push(.inbox, Self.decisions())

        #expect(await updates.next() == Self.decisionsUpdate())
        #expect(await live.current == .live)
    }

    @Test("one socket carries both channels")
    func oneSocket() async throws {
        let live = server.channel()
        var inbox = await live.updates(of: .inbox).makeAsyncIterator()
        var agents = await live.updates(of: .agents).makeAsyncIterator()

        let connection = try await server.connection(1)
        connection.send(.opened)
        await eventually("it joins both") { Set(connection.actions) == [.join(.inbox), .join(.agents)] }
        try connection.push(.agents, FixtureAPI.fixture(named: "listMyAgents"))
        try connection.push(.inbox, Self.decisions())

        #expect(await inbox.next() == Self.decisionsUpdate())
        #expect(await agents.next() == Self.agentsUpdate())
        #expect(server.connections.count == 1)
        #expect(connection.actions.count == 2)
    }

    @Test("two subscribers share one join")
    func sharedJoin() async throws {
        let live = server.channel()
        let first = await LiveListener(live.updates(of: .inbox))
        let second = await LiveListener(live.updates(of: .inbox))
        let agents = await LiveListener(live.updates(of: .agents))
        let connection = try await server.connection(1)
        connection.send(.opened)
        await eventually("it joins each channel once") { Set(connection.actions) == [.join(.inbox), .join(.agents)] }

        try connection.push(.inbox, Self.decisions())
        var firstUpdates = first.received.makeAsyncIterator()
        var secondUpdates = second.received.makeAsyncIterator()
        #expect(await firstUpdates.next() == Self.decisionsUpdate())
        #expect(await secondUpdates.next() == Self.decisionsUpdate())
        #expect(connection.actions.count == 2)

        first.stop()
        await eventually("the first listener stops") { await live.listenerCount(of: .inbox) == 1 }
        #expect(connection.actions.count == 2)

        second.stop()
        await eventually("it leaves me:inbox") { connection.actions.last == .leave(.inbox) }

        agents.stop()
        await eventually("it closes the socket") { connection.actions.last == .close }
        #expect(connection.actions.suffix(3) == [.leave(.inbox), .leave(.agents), .close])
        #expect(await live.current == .idle)
        #expect(await live.isRunning == false)
    }

    @Test("the same state again is not delivered")
    func sameStateOnce() async throws {
        let live = server.channel()
        var updates = await live.updates(of: .inbox).makeAsyncIterator()
        var agents = await live.updates(of: .agents).makeAsyncIterator()
        let connection = try await server.connection(1)
        connection.send(.opened)
        try connection.push(.inbox, Self.decisions())
        #expect(await updates.next() == Self.decisionsUpdate())
        #expect(await live.deliveries(of: .inbox) == 1)

        // The channel handles the socket's events in order, so once the agents'
        // update arrives the repeat sent before it has been handled.
        try connection.push(.inbox, Self.decisions())
        try connection.push(.agents, FixtureAPI.fixture(named: "listMyAgents"))
        #expect(await agents.next() == Self.agentsUpdate())
        #expect(await live.deliveries(of: .inbox) == 1)

        let changed = try Self.changedDecisions()
        connection.push(.inbox, changed)
        #expect(await updates.next() == Self.decisionsUpdate(changed))
        #expect(await live.deliveries(of: .inbox) == 2)
    }

    @Test("a new listener gets the newest state at once, without another join")
    func newestForNewListener() async throws {
        let live = server.channel()
        var first = await live.updates(of: .inbox).makeAsyncIterator()
        let connection = try await server.connection(1)
        connection.send(.opened)
        try connection.push(.inbox, Self.decisions())
        #expect(await first.next() == Self.decisionsUpdate())

        var second = await live.updates(of: .inbox).makeAsyncIterator()

        #expect(await second.next() == Self.decisionsUpdate())
        #expect(connection.actions == [.join(.inbox)])
    }

    // MARK: Reconnecting

    @Test("rejoins after reconnect")
    func rejoinsAfterReconnect() async throws {
        let live = server.channel()
        var updates = await live.updates(of: .inbox).makeAsyncIterator()
        let first = try await server.connection(1)
        first.send(.opened)
        first.send(.joined(.inbox))
        try first.push(.inbox, Self.decisions())
        #expect(await updates.next() == Self.decisionsUpdate())

        first.drop()

        let second = try await server.connection(2)
        #expect(second.token == "EXAMPLE-socket-2")
        #expect(server.pauses == [.seconds(1)])
        second.send(.opened)
        await eventually("it joins again") { second.actions == [.join(.inbox)] }
        let changed = try Self.changedDecisions()
        second.push(.inbox, changed)
        #expect(await updates.next() == Self.decisionsUpdate(changed))
        #expect(await live.current == .live)
    }

    @Test("a refused connect asks for a new token and connects again")
    func refusedConnect() async throws {
        let live = server.channel()
        let listener = await LiveListener(live.updates(of: .inbox))
        defer { listener.stop() }

        // A used or expired token is refused before the socket opens.
        try await server.connection(1).drop()

        let second = try await server.connection(2)
        #expect(second.token == "EXAMPLE-socket-2")
        #expect(server.asked == 2)
        second.send(.opened)
        await eventually("it joins") { second.actions == [.join(.inbox)] }
    }

    @Test("pauses longer after each failure, and starts over after a join")
    func backOff() async throws {
        let server = FakeLiveServer(answers: [.failed])
        let live = server.channel()
        let listener = await LiveListener(live.updates(of: .inbox))
        defer { listener.stop() }

        try await server.connection(1).drop()
        try await server.connection(2).drop()
        let third = try await server.connection(3)
        #expect(server.pauses == [.seconds(1), .seconds(2), .seconds(5)])

        third.send(.opened)
        third.send(.joined(.inbox))
        third.drop()
        _ = try await server.connection(4)

        #expect(server.pauses == [.seconds(1), .seconds(2), .seconds(5), .seconds(1)])
        #expect(LiveChannel.retryDelays.last == .seconds(30))
    }

    @Test("one channel joining while another is refused still backs off")
    func partialJoinBacksOff() async throws {
        let server = FakeLiveServer(answers: [.failed])
        let live = server.channel()
        let inbox = await LiveListener(live.updates(of: .inbox))
        let agents = await LiveListener(live.updates(of: .agents))
        defer {
            inbox.stop()
            agents.stop()
        }

        let first = try await server.connection(1)
        #expect(server.pauses == [.seconds(1)])
        first.send(.opened)
        await eventually("it joins both") { Set(first.actions) == [.join(.inbox), .join(.agents)] }
        first.send(.joined(.inbox))
        first.send(.refused(.agents, reason: "unauthorized"))
        _ = try await server.connection(2)

        #expect(server.pauses == [.seconds(1), .seconds(2)])
    }

    @Test("a refused join or a closed channel connects again with a new token", arguments: [
        LiveConnectionEvent.refused(.inbox, reason: "unauthorized"),
        .refused(.inbox, reason: nil),
        .channelClosed(.inbox)
    ])
    func refusedJoin(event: LiveConnectionEvent) async throws {
        let live = server.channel()
        let listener = await LiveListener(live.updates(of: .inbox))
        defer { listener.stop() }
        let first = try await server.connection(1)
        first.send(.opened)

        first.send(event)

        await eventually("it closes the socket") { first.actions.last == .close }
        let second = try await server.connection(2)
        #expect(second.token == "EXAMPLE-socket-2")
    }

    @Test("resume connects again at once with a new token")
    func resume() async throws {
        let live = server.channel()
        let listener = await LiveListener(live.updates(of: .inbox))
        defer { listener.stop() }
        let first = try await server.connection(1)
        first.send(.opened)
        first.send(.joined(.inbox))
        await eventually("it joins") { first.actions == [.join(.inbox)] }

        await live.resume()

        #expect(first.actions.last == .close)
        let second = try await server.connection(2)
        #expect(second.token == "EXAMPLE-socket-2")
        #expect(server.pauses.isEmpty)
        second.send(.opened)
        await eventually("it joins again") { second.actions == [.join(.inbox)] }
    }

    @Test("resume does nothing while nobody listens")
    func resumeWithoutListeners() async {
        let live = server.channel()

        await live.resume()

        #expect(await live.isRunning == false)
        #expect(server.asked == 0)
        #expect(await live.current == .idle)
    }

    // MARK: Signing out and stopping

    @Test("a revoke signs out")
    func revoke() async throws {
        let server = FakeLiveServer(answers: [.token("EXAMPLE-socket-1"), .signedOut])
        let live = server.channel()
        let listener = await LiveListener(live.updates(of: .inbox))
        defer { listener.stop() }
        let connection = try await server.connection(1)
        connection.send(.opened)
        connection.send(.joined(.inbox))

        // The server closes a revoked device's socket like any other, and then
        // refuses its next socket token.
        connection.drop()

        await eventually("it signs out") { server.signOuts == 1 }
        #expect(await live.current == .signedOut)
        #expect(await live.isRunning == false)
        #expect(server.asked == 2)
        #expect(server.connections.count == 1)
    }

    @Test("a revoke drops the last state, so the next listener never sees it")
    func revokeForgets() async throws {
        let server = FakeLiveServer(answers: [.token("EXAMPLE-socket-1"), .signedOut])
        let live = server.channel()
        let first = await LiveListener(live.updates(of: .inbox))
        let connection = try await server.connection(1)
        connection.send(.opened)
        try connection.push(.inbox, Self.decisions())
        var received = first.received.makeAsyncIterator()
        #expect(await received.next() == Self.decisionsUpdate())

        connection.drop()
        await eventually("it signs out") { await live.current == .signedOut }

        var next = await live.updates(of: .inbox).makeAsyncIterator()
        let second = try await server.connection(2)
        second.send(.opened)
        let changed = try Self.changedDecisions()
        second.push(.inbox, changed)
        #expect(await next.next() == Self.decisionsUpdate(changed))
        first.stop()
    }

    @Test("forget drops the last state and closes the socket until resumed")
    func forget() async throws {
        let live = server.channel()
        var first = await live.updates(of: .inbox).makeAsyncIterator()
        let connection = try await server.connection(1)
        connection.send(.opened)
        try connection.push(.inbox, Self.decisions())
        #expect(await first.next() == Self.decisionsUpdate())

        await live.forget()

        #expect(connection.actions.last == .close)
        #expect(await live.current == .idle)
        #expect(await live.isRunning == false)

        var next = await live.updates(of: .inbox).makeAsyncIterator()
        let second = try await server.connection(2)
        second.send(.opened)
        let changed = try Self.changedDecisions()
        second.push(.inbox, changed)
        #expect(await next.next() == Self.decisionsUpdate(changed))
    }

    @Test("without the plan it stops until resumed")
    func unavailable() async throws {
        let server = FakeLiveServer(answers: [.unavailable])
        let live = server.channel()
        let listener = await LiveListener(live.updates(of: .inbox))
        defer { listener.stop() }

        await eventually("it stops") { await live.current == .unavailable }
        #expect(await live.isRunning == false)
        #expect(server.connections.isEmpty)
        #expect(server.signOuts == 0)

        await live.resume()

        let connection = try await server.connection(1)
        #expect(connection.token == "EXAMPLE-socket-2")
    }

    @Test("reports the state now, then each change")
    func states() async throws {
        let live = server.channel()
        var states = await live.states().makeAsyncIterator()
        #expect(await states.next() == .idle)

        let listener = await LiveListener(live.updates(of: .inbox))
        let connection = try await server.connection(1)
        connection.send(.opened)
        await eventually("it is live") { await live.current == .live }
        #expect(await states.next() == .live)

        listener.stop()
        #expect(await states.next() == .idle)
    }

    // MARK: Fixtures

    private static func decisions() throws -> Data {
        try FixtureAPI.fixture(named: "listMyDecisions")
    }

    private static func changedDecisions() throws -> Data {
        try FixtureChange.firstItem(of: "listMyDecisions") { $0["since"] = "2026-11-19T10:00:00Z" }
    }

    private static func decisionsUpdate(_ body: Data? = nil) -> LiveUpdate? {
        guard let body = body ?? (try? decisions()) else { return nil }
        return LiveUpdate(topic: .inbox, event: "decisions", payload: body)
    }

    private static func agentsUpdate() -> LiveUpdate? {
        guard let body = try? FixtureAPI.fixture(named: "listMyAgents") else { return nil }
        return LiveUpdate(topic: .agents, event: "agents", payload: body)
    }
}
