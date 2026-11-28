/// Which decision a `DecisionToast` reports, which names it for the UI tests
/// and the accessibility audit.
enum DecisionToastKind: Hashable, Sendable {
    case approved
    case changesRequested

    /// The design's approval toast has a checkmark; its sent toast has none.
    var showsCheckmark: Bool { self == .approved }

    var toastIdentifier: String {
        switch self {
        case .approved: "review-approved-toast"
        case .changesRequested: "review-changes-toast"
        }
    }

    var messageIdentifier: String {
        switch self {
        case .approved: "review-approved"
        case .changesRequested: "review-changes-requested"
        }
    }
}
