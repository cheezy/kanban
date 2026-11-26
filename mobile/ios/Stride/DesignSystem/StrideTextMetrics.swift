import CoreGraphics

/// A text style at one text size.
struct StrideTextMetrics: Equatable, Sendable {
    let pointSize: CGFloat
    /// The family the system found for the style, which is the style's own
    /// while its font is bundled.
    let familyName: String
    let tracking: CGFloat
    let lineSpacing: CGFloat
}
