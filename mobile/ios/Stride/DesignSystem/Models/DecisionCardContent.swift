/// What a decision card shows. Every string but the kind comes from the
/// server and is shown as plain text.
struct DecisionCardContent: Hashable, Sendable {
    let kind: DecisionKind
    let identifier: String
    let title: String
    let priority: Priority?
    let holdsUp: Int
    let agent: AgentAvatarContent?
    let issue: String?
    let verdicts: [Verdict]

    init(
        kind: DecisionKind,
        identifier: String,
        title: String,
        priority: Priority? = nil,
        holdsUp: Int = 0,
        agent: AgentAvatarContent? = nil,
        issue: String? = nil,
        verdicts: [Verdict] = []
    ) {
        self.kind = kind
        self.identifier = identifier
        self.title = title
        self.priority = priority
        self.holdsUp = max(0, holdsUp)
        self.agent = agent
        self.issue = issue
        self.verdicts = verdicts
    }
}
