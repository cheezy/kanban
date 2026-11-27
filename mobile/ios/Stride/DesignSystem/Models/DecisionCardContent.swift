import Foundation

/// What a decision card shows. Every string but the kind and the age comes
/// from the server and is shown as plain text.
struct DecisionCardContent: Hashable, Sendable {
    let kind: DecisionKind
    let identifier: String
    let title: String
    let priority: Priority?
    let holdsUp: Int
    let agent: AgentAvatarContent?
    let issue: String?
    let verdicts: [Verdict]
    /// When it started waiting, which the card shows as an age such as "2m".
    let since: Date?

    init(
        kind: DecisionKind,
        identifier: String,
        title: String,
        priority: Priority? = nil,
        holdsUp: Int = 0,
        agent: AgentAvatarContent? = nil,
        issue: String? = nil,
        verdicts: [Verdict] = [],
        since: Date? = nil
    ) {
        self.kind = kind
        self.identifier = identifier
        self.title = title
        self.priority = priority
        self.holdsUp = max(0, holdsUp)
        self.agent = agent
        self.issue = issue
        self.verdicts = verdicts
        self.since = since
    }

    /// How long it has waited at `now`, in its largest unit: "2m" when
    /// `width` is narrow, "2 minutes" when it is wide, for VoiceOver.
    func age(at now: Date, in locale: Locale, width: Duration.UnitsFormatStyle.UnitWidth = .narrow) -> String? {
        guard let since else { return nil }

        let style = Duration.UnitsFormatStyle(
            allowedUnits: [.days, .hours, .minutes],
            width: width,
            maximumUnitCount: 1
        )
        let waited = max(0, now.timeIntervalSince(since))
        return Duration.seconds(waited).formatted(style.locale(locale))
    }
}
