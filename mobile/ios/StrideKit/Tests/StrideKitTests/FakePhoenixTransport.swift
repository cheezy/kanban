import Foundation
import os
@preconcurrency import SwiftPhoenixClient

/// Plays the server's side of a Phoenix socket for `PhoenixConnection`: it
/// records each message the socket sends and answers through the socket's
/// delegate, as `URLSessionTransport` does for a real server.
final class FakePhoenixTransport: PhoenixTransport, @unchecked Sendable {
    // Unchecked: every stored value is read and written under `state`.

    /// A message the socket sent, from the protocol's
    /// `[join_ref, ref, topic, event, payload]` array.
    struct Sent: Equatable {
        let joinRef: String?
        let ref: String?
        let topic: String
        let event: String
    }

    private struct State {
        var readyState = PhoenixTransportReadyState.closed
        var delegate: (any PhoenixTransportDelegate)?
        var sent: [Sent] = []
        var disconnects = 0
    }

    let url: URL
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    init(url: URL) {
        self.url = url
    }

    var sent: [Sent] { state.withLock { $0.sent } }
    var disconnects: Int { state.withLock { $0.disconnects } }

    // MARK: PhoenixTransport

    var readyState: PhoenixTransportReadyState { state.withLock { $0.readyState } }

    var delegate: (any PhoenixTransportDelegate)? {
        get { state.withLockUnchecked { $0.delegate } }
        set { state.withLockUnchecked { $0.delegate = newValue } }
    }

    func connect(with headers: [String: Any]) {
        state.withLock { $0.readyState = .connecting }
    }

    func disconnect(code: Int, reason: String?) {
        state.withLock {
            $0.readyState = .closed
            $0.disconnects += 1
        }
    }

    func send(data: Data) {
        guard
            let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
            array.count == 5,
            let topic = array[2] as? String,
            let event = array[3] as? String
        else { return }

        let message = Sent(joinRef: array[0] as? String, ref: array[1] as? String, topic: topic, event: event)
        state.withLock { $0.sent.append(message) }
    }

    // MARK: The server's side

    /// The socket's handshake succeeds.
    func open() {
        state.withLock { $0.readyState = .open }
        delegate?.onOpen(response: nil)
    }

    /// The handshake is refused, as for a used or expired token.
    func refuse() {
        state.withLock { $0.readyState = .closed }
        delegate?.onError(error: URLError(.badServerResponse), response: nil)
    }

    /// The server or the network closes the socket.
    func drop(code: Int) {
        state.withLock { $0.readyState = .closed }
        delegate?.onClose(code: code, reason: nil)
    }

    /// Answers the last `event` the socket sent on `topic`.
    func reply(to event: String, on topic: String, status: String, response: [String: Any] = [:]) throws {
        let request = try sentMessage(event, on: topic)
        try receive([request.joinRef, request.ref, topic, "phx_reply", ["status": status, "response": response]])
    }

    /// Pushes `event` on `topic`, as a channel broadcasts its state.
    func push(_ event: String, on topic: String, payload: [String: Any]) throws {
        try receive([nil, nil, topic, event, payload])
    }

    /// Closes the channel on `topic` from the server's side.
    func closeChannel(_ topic: String) throws {
        let join = try sentMessage("phx_join", on: topic)
        try receive([join.joinRef, nil, topic, "phx_close", [String: Any]()])
    }

    private func sentMessage(_ event: String, on topic: String) throws -> Sent {
        guard let message = sent.last(where: { $0.topic == topic && $0.event == event }) else {
            throw FakeTransportError.nothingSent(event, topic)
        }
        return message
    }

    private func receive(_ message: [Any?]) throws {
        let array = message.map { $0 ?? NSNull() }
        let data = try JSONSerialization.data(withJSONObject: array)
        delegate?.onMessage(message: String(decoding: data, as: UTF8.self))
    }
}

enum FakeTransportError: Error {
    case nothingSent(String, String)
}
