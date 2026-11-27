/// A channel `LiveChannel` joins. Each one pushes a single kind of update.
public enum LiveTopic: String, Sendable, CaseIterable {
    /// What waits on the person, for Now and the decisions badge.
    case inbox = "me:inbox"

    /// The person's agents and goals, for Agents.
    case agents = "me:agents"

    /// The one event the channel pushes: its full state, on join and after each
    /// change.
    var event: String {
        switch self {
        case .inbox: "decisions"
        case .agents: "agents"
        }
    }
}
