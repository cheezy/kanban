import SwiftUI

/// A chip that adds something to a field, such as a failed verdict's note:
/// footnote text in ink-2 on a surface capsule with a line border, drawn 32
/// points high with a 44-point target. Off, it reads in ink-3, as the
/// design's `.chip[disabled]` does, and never fades (W2800).
struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChipButtonLabel(configuration: configuration)
    }
}

private struct ChipButtonLabel: View {
    @Environment(\.isEnabled) private var isEnabled

    let configuration: ButtonStyleConfiguration

    var body: some View {
        configuration.label
            .textStyle(.footnote)
            .foregroundStyle((isEnabled ? ColorToken.ink2 : .ink3).color)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(ColorToken.surface.color, in: Capsule())
            .overlay { Capsule().strokeBorder(ColorToken.line.color, lineWidth: 1) }
            .opacity(configuration.isPressed ? 0.75 : 1)
            // The chip is drawn 32 high; its target is 44.
            .padding(.vertical, 6)
            .contentShape(Rectangle())
    }
}
