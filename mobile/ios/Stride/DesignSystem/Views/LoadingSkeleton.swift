import SwiftUI

/// Grey cards in the shape of decision cards while the first answer is on its
/// way. Each screen passes its own label, card height and identifier.
struct LoadingSkeleton: View {
    let label: LocalizedStringResource
    let cardHeight: CGFloat
    let identifier: String

    var body: some View {
        VStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: DesignTokens.Radius.xl)
                    .fill(ColorToken.surfaceSunken.color)
                    .frame(height: cardHeight)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(identifier)
    }
}
