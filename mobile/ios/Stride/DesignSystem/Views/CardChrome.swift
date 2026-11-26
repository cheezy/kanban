import SwiftUI

/// The surface, border, corners and shadow a card sits on.
struct CardChrome: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.xl)

        content
            .padding(EdgeInsets(top: 14, leading: 14, bottom: 12, trailing: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ColorToken.surface.color, in: shape)
            .overlay { shape.strokeBorder(ColorToken.line.color, lineWidth: 1) }
            .shadow(color: ColorToken.ink.color.opacity(0.06), radius: 2, y: 1)
    }
}

extension View {
    /// Puts the view on a card.
    func cardChrome() -> some View {
        modifier(CardChrome())
    }
}
