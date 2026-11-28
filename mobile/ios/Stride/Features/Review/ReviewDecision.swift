import Foundation

/// What the person who decided first decided.
enum ReviewDecision: Hashable, Sendable {
    case approved
    case changesRequested
    case other

    init(apiValue: String?) {
        switch apiValue {
        case "approved": self = .approved
        case "changes_requested": self = .changesRequested
        default: self = .other
        }
    }
}
