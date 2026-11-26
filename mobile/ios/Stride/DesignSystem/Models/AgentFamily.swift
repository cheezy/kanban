/// Who an avatar stands for: one of the agents the design gives a colour, any
/// other agent, or a person.
enum AgentFamily: CaseIterable, Sendable {
    case claude
    case codex
    case cursor
    case aider
    case otherAgent
    case person

    /// An agent by the words in its name, such as "Claude Opus 5.5".
    init(name: String, isPerson: Bool) {
        let words = name.lowercased()

        self =
            if isPerson { .person }
            else if words.contains("claude") { .claude }
            else if words.contains("codex") { .codex }
            else if words.contains("cursor") { .cursor }
            else if words.contains("aider") { .aider }
            else { .otherAgent }
    }

    /// The initials' colour. The design's solid fills have no token that keeps
    /// text readable in dark mode, so each family uses a soft and ink pair that
    /// the token tests hold to 4.5:1.
    var ink: ColorToken {
        switch self {
        case .claude: .strideOrangeInk
        case .codex: .strideVioletInk
        case .cursor, .person: .labelBlue
        case .aider: .labelGreen
        case .otherAgent: .labelGray
        }
    }

    var fill: ColorToken {
        switch self {
        case .claude: .strideOrangeSoft
        case .codex: .strideVioletSoft
        case .cursor, .person: .labelBlueSoft
        case .aider: .labelGreenSoft
        case .otherAgent: .labelGraySoft
        }
    }
}
