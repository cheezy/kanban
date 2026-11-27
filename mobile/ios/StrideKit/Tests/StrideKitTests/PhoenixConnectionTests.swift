import Foundation
import os
import Testing

@testable import StrideKit

/// `PhoenixConnection` against a fake transport that plays the Stride server,
/// so the events it reports come from SwiftPhoenixClient's real message
/// handling.
@Suite(.timeLimit(.minutes(1)))
struct PhoenixConnectionTests {
    private let transports = OSAllocatedUnfairLock<[FakePhoenixTransport]>(uncheckedState: [])

    @Test("opens the socket at the Stride endpoint with the token as a parameter")
    func opens() async throws {
        let connection = connect()
        let transport = try await transport()
        var events = connection.events.makeAsyncIterator()

        let url = try #require(URLComponents(url: transport.url, resolvingAgainstBaseURL: false))
        #expect(url.host == StrideClient.serverURL.host)
        #expect(url.path == "/api/socket/websocket")
        let parameters = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(parameters == ["token": "EXAMPLE-socket-token", "vsn": "2.0.0"])

        transport.open()

        #expect(await events.next() == .opened)
    }

    @Test("a refused connect ends the connection")
    func refusedConnect() async throws {
        let connection = connect()
        let transport = try await transport()

        transport.refuse()

        #expect(await Self.all(connection.events).isEmpty)
        #expect(transport.disconnects == 1)
    }

    @Test("a dropped socket ends the connection, which never reconnects")
    func dropped() async throws {
        let connection = connect()
        let transport = try await transport()
        var events = connection.events.makeAsyncIterator()
        transport.open()
        #expect(await events.next() == .opened)

        transport.drop(code: 1006)

        #expect(await events.next() == nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(transports.withLockUnchecked { $0.count } == 1)
    }

    @Test("joins a channel the server accepts")
    func joined() async throws {
        let (connection, transport) = try await openConnection()
        var events = connection.events.makeAsyncIterator()

        connection.join(.inbox)
        await eventually("it sends the join") { transport.sent.contains { $0.event == "phx_join" } }
        try transport.reply(to: "phx_join", on: "me:inbox", status: "ok")

        #expect(await events.next() == .joined(.inbox))
    }

    @Test("a refused join carries the server's reason")
    func refusedJoin() async throws {
        let (connection, transport) = try await openConnection()
        var events = connection.events.makeAsyncIterator()

        connection.join(.agents)
        await eventually("it sends the join") { transport.sent.contains { $0.event == "phx_join" } }
        try transport.reply(to: "phx_join", on: "me:agents", status: "error", response: ["reason": "unauthorized"])

        #expect(await events.next() == .refused(.agents, reason: "unauthorized"))
    }

    @Test("a join with no answer is refused when it times out")
    func joinTimeout() async throws {
        let (connection, _) = try await openConnection(joinTimeout: 0.2)
        var events = connection.events.makeAsyncIterator()

        connection.join(.inbox)

        #expect(await events.next() == .refused(.inbox, reason: nil))
    }

    @Test("a pushed state arrives as its JSON")
    func pushed() async throws {
        let (connection, transport) = try await openJoined(.inbox)
        var events = connection.events.makeAsyncIterator()

        try transport.push("decisions", on: "me:inbox", payload: ["data": ["items": [["id": 7]]]])

        guard case .pushed(let topic, let event, let payload) = await events.next() else {
            Issue.record("No push arrived")
            return
        }
        #expect(topic == .inbox)
        #expect(event == "decisions")
        let json = try #require(JSONSerialization.jsonObject(with: payload) as? NSDictionary)
        #expect(json == ["data": ["items": [["id": 7]]]])
    }

    @Test("a channel the server closes is reported")
    func channelClosed() async throws {
        let (connection, transport) = try await openJoined(.inbox)
        var events = connection.events.makeAsyncIterator()

        try transport.closeChannel("me:inbox")

        #expect(await events.next() == .channelClosed(.inbox))
    }

    @Test("a channel it leaves is not reported as closed")
    func left() async throws {
        let (connection, transport) = try await openJoined(.inbox)

        connection.leave(.inbox)
        await eventually("it sends the leave") { transport.sent.contains { $0.event == "phx_leave" } }
        try transport.reply(to: "phx_leave", on: "me:inbox", status: "ok")
        try await Task.sleep(for: .milliseconds(200))
        connection.close()

        #expect(await Self.all(connection.events).isEmpty)
        #expect(transport.disconnects == 1)
    }

    @Test("a join after closing sends nothing, and closing twice disconnects once")
    func closed() async throws {
        let (connection, transport) = try await openConnection()

        connection.close()
        connection.close()
        connection.join(.inbox)

        #expect(await Self.all(connection.events).isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!transport.sent.contains { $0.event == "phx_join" })
        #expect(transport.disconnects == 1)
    }

    @Test("a reader that stops listening closes the socket")
    func readerStops() async throws {
        let (connection, transport) = try await openConnection()

        let reader = Task { for await _ in connection.events {} }
        reader.cancel()

        await eventually("it disconnects") { transport.disconnects == 1 }
    }

    // MARK: Helpers

    private func connect(joinTimeout: TimeInterval = 10) -> PhoenixConnection {
        PhoenixConnection(socketToken: "EXAMPLE-socket-token", joinTimeout: joinTimeout) { url in
            let transport = FakePhoenixTransport(url: url)
            transports.withLockUnchecked { $0.append(transport) }
            return transport
        }
    }

    private func transport() async throws -> FakePhoenixTransport {
        await eventually("the socket connects") { transports.withLockUnchecked { $0.count } == 1 }
        return try #require(transports.withLockUnchecked { $0.first })
    }

    /// A connection whose socket is open, with its `.opened` event read.
    private func openConnection(joinTimeout: TimeInterval = 10) async throws -> (PhoenixConnection, FakePhoenixTransport) {
        let connection = connect(joinTimeout: joinTimeout)
        let transport = try await transport()
        var events = connection.events.makeAsyncIterator()
        transport.open()
        #expect(await events.next() == .opened)
        return (connection, transport)
    }

    /// A connection that has joined `topic`, with its events so far read.
    private func openJoined(_ topic: LiveTopic) async throws -> (PhoenixConnection, FakePhoenixTransport) {
        let (connection, transport) = try await openConnection()
        var events = connection.events.makeAsyncIterator()
        connection.join(topic)
        await eventually("it sends the join") { transport.sent.contains { $0.event == "phx_join" } }
        try transport.reply(to: "phx_join", on: topic.rawValue, status: "ok")
        #expect(await events.next() == .joined(topic))
        return (connection, transport)
    }

    private static func all(_ events: AsyncStream<LiveConnectionEvent>) async -> [LiveConnectionEvent] {
        var all: [LiveConnectionEvent] = []
        for await event in events { all.append(event) }
        return all
    }
}
