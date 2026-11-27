/// One socket to the Stride server, opened with one socket token.
///
/// A connection is never used twice: once its events end, `LiveChannel` asks for
/// a new token and opens a new connection, so it never reconnects or rejoins by
/// itself.
protocol LiveConnection: AnyObject, Sendable {
    /// What the socket reports, until it closes or its connect is refused.
    var events: AsyncStream<LiveConnectionEvent> { get }

    func join(_ topic: LiveTopic)

    func leave(_ topic: LiveTopic)

    /// Closes the socket and ends `events`.
    func close()
}

/// Opens a connection with a single-use socket token.
typealias LiveConnector = @Sendable (_ socketToken: String) -> any LiveConnection
