import Foundation
@preconcurrency import SwiftPhoenixClient

/// A `LiveConnection` over SwiftPhoenixClient: one socket on the Stride server,
/// opened with a single-use socket token.
///
/// It never reconnects: the token cannot be used twice, so `LiveChannel` opens a
/// new connection with a new token instead. The token travels only as the
/// `token` connect parameter over TLS, and the socket's logger stays unset, so
/// the URL that holds it is never written anywhere.
final class PhoenixConnection: LiveConnection, @unchecked Sendable {
    // Unchecked: `socket` and `channels` are touched only on `queue`, and the
    // continuation is safe from any thread.

    /// The socket on the only server the app talks to. SwiftPhoenixClient adds
    /// `/websocket` and the parameters, and turns `https` into `wss`.
    static let endpoint = StrideClient.serverURL.appending(path: "api/socket")

    let events: AsyncStream<LiveConnectionEvent>
    private let continuation: AsyncStream<LiveConnectionEvent>.Continuation
    private let queue = DispatchQueue(label: "StrideKit.PhoenixConnection")
    private let socket: Socket
    private var channels: [LiveTopic: Channel] = [:]
    private var isClosed = false

    /// How long the server has to answer a join before it counts as refused.
    private let joinTimeout: TimeInterval

    convenience init(socketToken: String) {
        self.init(socketToken: socketToken) {
            URLSessionTransport(url: $0, configuration: Self.sessionConfiguration)
        }
    }

    /// Opens the socket through `transport`, which the tests replace with a
    /// fake that plays the server's side.
    init(
        socketToken: String,
        joinTimeout: TimeInterval = 10,
        transport: @escaping (URL) -> any PhoenixTransport
    ) {
        (events, continuation) = AsyncStream.makeStream(of: LiveConnectionEvent.self)
        self.joinTimeout = joinTimeout
        socket = Socket(
            endPoint: Self.endpoint.absoluteString,
            transport: transport,
            paramsClosure: { ["token": socketToken] }
        )
        continuation.onTermination = { [weak self] _ in self?.close() }
        queue.async { self.open() }
    }

    func join(_ topic: LiveTopic) {
        queue.async { self.joinOnQueue(topic) }
    }

    func leave(_ topic: LiveTopic) {
        queue.async {
            guard let channel = self.channels.removeValue(forKey: topic) else { return }
            channel.leave()
        }
    }

    func close() {
        queue.async { self.end() }
    }

    /// Keeps no cookies and no cached responses, as the API client does.
    private static var sessionConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return configuration
    }

    private func open() {
        socket.onOpen { [continuation] in continuation.yield(.opened) }
        socket.onClose { [weak self] in self?.close() }
        // A refused connect, such as for a used or expired token, is an error
        // with no reason.
        socket.onError { [weak self] _ in self?.close() }
        socket.connect()
    }

    private func joinOnQueue(_ topic: LiveTopic) {
        guard !isClosed, channels[topic] == nil else { return }

        let channel = socket.channel(topic.rawValue)
        channels[topic] = channel
        let continuation = continuation

        channel.on(topic.event) { message in
            guard let payload = try? JSONSerialization.data(withJSONObject: message.payload) else { return }
            continuation.yield(.pushed(topic, event: topic.event, payload: payload))
        }
        channel.onClose { [weak self, weak channel] _ in
            guard let self, let channel else { return }
            self.queue.async {
                // A channel this connection left is not one the server closed.
                guard self.channels[topic] === channel else { return }
                self.channels[topic] = nil
                continuation.yield(.channelClosed(topic))
            }
        }
        channel.join(timeout: joinTimeout)
            .receive("ok") { _ in continuation.yield(.joined(topic)) }
            .receive("error") { message in
                // `Message` has already unwrapped the reply's `response`.
                continuation.yield(.refused(topic, reason: message.payload["reason"] as? String))
            }
            .receive("timeout") { _ in continuation.yield(.refused(topic, reason: nil)) }
    }

    private func end() {
        guard !isClosed else { return }

        isClosed = true
        socket.releaseCallbacks()
        socket.disconnect()
        channels = [:]
        continuation.finish()
    }
}
