import SwiftUI

/// The surface, border, corners and shadow a card sits on.
struct CardChrome: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.xl)

        content
            .padding(EdgeInsets(top: 14, leading: 14, bottom: 12, trailing: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            // The shadow is on the surface alone: on the whole card it would be
            // drawn under every text and button too, which blurs their edges
            // and fails the accessibility audit's contrast check (W2793).
            .background {
                shape
                    .fill(ColorToken.surface.color)
                    .shadow(color: ColorToken.ink.color.opacity(0.06), radius: 2, y: 1)
            }
            .overlay { shape.strokeBorder(ColorToken.line.color, lineWidth: 1) }
    }
}

extension View {
    /// Puts the view on a card.
    func cardChrome() -> some View {
        modifier(CardChrome())
    }
}
