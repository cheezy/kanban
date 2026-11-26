/// What a line of a diff is.
enum DiffLineKind: String, CaseIterable, Sendable {
    case added = "add"
    case removed = "del"
    case context = "ctx"
    case hunk

    /// From the API's line type; anything unknown is context.
    init(apiValue: String?) {
        self = apiValue.flatMap(Self.init(rawValue:)) ?? .context
    }

    /// The line's background, nil for none.
    var background: ColorToken? {
        switch self {
        case .added: .stDoneSoft
        case .removed: .stBlockedSoft
        case .context: nil
        case .hunk: .surfaceSunken
        }
    }

    var numberInk: ColorToken {
        switch self {
        case .added: .stDone
        case .removed: .stBlocked
        case .context, .hunk: .ink3
        }
    }

    var textInk: ColorToken {
        switch self {
        case .added: .ink
        case .removed, .context: .ink2
        case .hunk: .ink3
        }
    }

    /// The marker before the text, so a line is told apart without colour.
    var marker: String {
        switch self {
        case .added: "+"
        case .removed: "−"
        case .context, .hunk: " "
        }
    }
}
