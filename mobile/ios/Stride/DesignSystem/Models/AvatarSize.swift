import CoreGraphics

/// The design's three avatar sizes, at the default text size.
enum AvatarSize: Sendable {
    /// 36 points, as in a list of agents.
    case regular
    /// 28 points.
    case medium
    /// 22 points, as beside a card's agent name.
    case small

    var side: CGFloat {
        switch self {
        case .regular: 36
        case .medium: 28
        case .small: 22
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .regular: 8
        case .medium: 7
        case .small: 5
        }
    }
}
