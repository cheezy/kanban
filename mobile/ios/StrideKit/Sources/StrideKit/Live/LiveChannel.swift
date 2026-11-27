import Foundation

/// The app's live updates: one socket to the Stride server that carries both
/// `me:inbox` and `me:agents`.
///
/// A screen reads `updates(of:)`. The first listener opens the socket and joins
/// its channel, later listeners share that join, and the socket closes when the
/// last listener stops. Every connect asks the API for a new single-use socket
/// token. After a drop it pauses and connects again, and each channel sends its
/// full state on join, so nothing is merged. `resume()` connects again at once,
/// for when the app comes back to the foreground.
///
/// The server closes a revoked device's socket like any other, so a revoke shows
/// on the next connect: the token request fails because the sign-in has ended,
/// and `LiveChannel` signs the app out and stops.
public actor LiveChannel {
    typealias SocketToken = @Sendable () async -> SocketTokenAnswer
    typealias Pause = @Sendable (Duration) async throws -> Void

    /// The pause before each connect after a drop, by how many connects in a
    /// row have failed. A connect on which the server accepts every listened
    /// channel starts the count again.
    static let retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(30)]

    private let socketToken: SocketToken
    private let connect: LiveConnector
    private let pause: Pause
    private let signOut: @Sendable () async -> Void

    private var listeners: [LiveTopic: [UUID: AsyncStream<LiveUpdate>.Continuation]] = [:]
    private var latest: [LiveTopic: LiveUpdate] = [:]
    private var watchers: [UUID: AsyncStream<LiveState>.Continuation] = [:]
    private var state = LiveState.idle
    private var connection: (any LiveConnection)?
    private var joined: Set<LiveTopic> = []
    /// The channels the server accepted on this connection.
    private var accepted: Set<LiveTopic> = []
    private var run: Task<Void, Never>?
    /// Which run is current. A run that has been replaced stops at its next step.
    private var generation = 0
    private var failures = 0

    /// Signs the app out through `store` when the sign-in turns out to have ended.
    public init(api: any StrideAPI, store: AuthStore) {
        self.init(
            socketToken: { await SocketTokenAnswer.asking(api) },
            connect: { PhoenixConnection(socketToken: $0) },
            pause: { try await Task.sleep(for: $0) },
            signOut: { try? await store.clear() }
        )
    }

    init(
        socketToken: @escaping SocketToken,
        connect: @escaping LiveConnector,
        pause: @escaping Pause,
        signOut: @escaping @Sendable () async -> Void
    ) {
        self.socketToken = socketToken
        self.connect = connect
        self.pause = pause
        self.signOut = signOut
    }

    /// The channel's newest full state, then each one it pushes, until the
    /// caller stops listening. Only the newest waits for a slow reader.
    public func updates(of topic: LiveTopic) -> AsyncStream<LiveUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: LiveUpdate.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stopListening(to: topic, id: id) }
        }

        listeners[topic, default: [:]][id] = continuation
        if let update = latest[topic] { continuation.yield(update) }
        join(topic)
        if run == nil { restart() }
        return stream
    }

    /// The state now, then each change, until the caller stops listening.
    public func states() -> AsyncStream<LiveState> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: LiveState.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stopWatching(id) }
        }

        watchers[id] = continuation
        continuation.yield(state)
        return stream
    }

    /// Connects again at once with a new token, so each channel sends its full
    /// state. The app calls it when it comes to the foreground. It does nothing
    /// while nobody listens.
    public func resume() {
        guard !listeners.isEmpty else { return }

        restart()
    }

    /// Drops each channel's newest state and closes the socket. The app calls it
    /// when the person signs out, so whoever signs in next never sees the last
    /// person's state. Listeners stay, and `resume()` connects again for them.
    public func forget() {
        latest = [:]
        stopRunning()
        if state != .signedOut, state != .unavailable { set(.idle) }
    }

    /// Whether a run is connecting, connected or pausing.
    var isRunning: Bool { run != nil }

    var current: LiveState { state }

    func listenerCount(of topic: LiveTopic) -> Int {
        listeners[topic]?.count ?? 0
    }

    // MARK: Running

    private func restart() {
        stopRunning()
        failures = 0
        let current = generation
        run = Task { await keepConnected(current) }
    }

    private func stopRunning() {
        generation += 1
        run?.cancel()
        run = nil
        closeConnection()
    }

    private func isCurrent(_ run: Int) -> Bool {
        run == generation && !Task.isCancelled
    }

    private func keepConnected(_ run: Int) async {
        while isCurrent(run) {
            set(.connecting)
            let answer = await socketToken()
            guard isCurrent(run) else { return }

            switch answer {
            case .token(let token):
                await stayConnected(with: token, run: run)
            case .signedOut:
                stopRunning()
                latest = [:]
                set(.signedOut)
                await signOut()
                return
            case .unavailable:
                stopRunning()
                set(.unavailable)
                return
            case .failed:
                break
            }

            guard isCurrent(run) else { return }
            set(.waiting)
            let delay = Self.retryDelays[min(failures, Self.retryDelays.count - 1)]
            failures += 1
            do { try await pause(delay) } catch { return }
        }
    }

    private func stayConnected(with token: String, run: Int) async {
        let connection = connect(token)
        self.connection = connection

        for await event in connection.events {
            guard isCurrent(run) else { return }
            handle(event, from: connection)
        }

        guard self.connection === connection else { return }
        self.connection = nil
        joined = []
        accepted = []
    }

    private func handle(_ event: LiveConnectionEvent, from connection: any LiveConnection) {
        switch event {
        case .opened:
            set(.live)
            for topic in listeners.keys { join(topic) }
        case .joined(let topic):
            accepted.insert(topic)
            // One channel joining is not a good connect while another is refused.
            if Set(listeners.keys).isSubset(of: accepted) { failures = 0 }
        case .refused, .channelClosed:
            // The next connect finds out why: a new token is refused when the
            // sign-in has ended or the plan has lapsed.
            connection.close()
        case .pushed(let topic, let event, let payload):
            deliver(LiveUpdate(topic: topic, event: event, payload: payload), on: topic)
        }
    }

    private func join(_ topic: LiveTopic) {
        guard state == .live, let connection, !joined.contains(topic) else { return }

        joined.insert(topic)
        connection.join(topic)
    }

    private func deliver(_ update: LiveUpdate?, on topic: LiveTopic) {
        guard let update, latest[topic] != update else { return }

        latest[topic] = update
        for listener in listeners[topic, default: [:]].values {
            listener.yield(update)
        }
    }

    private func closeConnection() {
        connection?.close()
        connection = nil
        joined = []
        accepted = []
    }

    private func set(_ newState: LiveState) {
        guard state != newState else { return }

        state = newState
        for watcher in watchers.values {
            watcher.yield(newState)
        }
    }

    // MARK: Listeners

    private func stopListening(to topic: LiveTopic, id: UUID) {
        listeners[topic]?[id] = nil
        guard listeners[topic]?.isEmpty == true else { return }

        listeners[topic] = nil
        latest[topic] = nil
        accepted.remove(topic)
        if joined.remove(topic) != nil { connection?.leave(topic) }
        guard listeners.isEmpty else { return }

        stopRunning()
        if state != .signedOut, state != .unavailable { set(.idle) }
    }

    private func stopWatching(_ id: UUID) {
        watchers[id] = nil
    }
}
