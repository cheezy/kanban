import SwiftUI

/// The pinned bar's chrome: a readable column on a surface with a line
/// above it. Inline buttons take the scrolled screen's own padding. The review and
/// file screens share it.
struct PinnedBar: ViewModifier {
    let isPinned: Bool

    func body(content: Content) -> some View {
        if isPinned {
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .background(ColorToken.surface.color)
                .overlay(alignment: .top) { Divider().overlay(ColorToken.line.color) }
        } else {
            content
                .padding(.top, 8)
        }
    }
}
