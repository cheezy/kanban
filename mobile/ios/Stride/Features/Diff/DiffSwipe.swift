import CoreGraphics

/// When a sideways movement counts as a page turn.
enum DiffSwipe {
    /// A movement pages when it runs more than 80 points across and
    /// more than twice as far across as up or down.
    static func pages(width: CGFloat, height: CGFloat) -> Bool {
        abs(width) > 80 && abs(width) > abs(height) * 2
    }

    /// A pan begins only when it sets out mostly sideways, so a scroll never
    /// waits on it.
    static func begins(velocity: CGPoint) -> Bool {
        abs(velocity.x) > abs(velocity.y) * 2
    }
}
