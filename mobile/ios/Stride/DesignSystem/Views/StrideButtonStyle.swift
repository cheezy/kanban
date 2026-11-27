import SwiftUI

/// The design's `.btn`: at least 44 points high, a surface button with an input
/// border, or ink with surface text for a screen's main step. A disabled one
/// is sunken with a dashed border, as the design draws an action that waits
/// for a connection.
struct StrideButtonStyle: ButtonStyle {
    var isPrimary = false

    func makeBody(configuration: Configuration) -> some View {
        StrideButtonLabel(configuration: configuration, isPrimary: isPrimary)
    }
}

private struct StrideButtonLabel: View {
    @Environment(\.isEnabled) private var isEnabled

    let configuration: ButtonStyleConfiguration
    let isPrimary: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.lg)

        configuration.label
            .textStyle(.body)
            .fontWeight(.medium)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(ink.color)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(fill.color, in: shape)
            .overlay {
                if !isPrimary || !isEnabled {
                    shape.strokeBorder(
                        Color(.lineInput),
                        style: StrokeStyle(lineWidth: 1, dash: isEnabled ? [] : [4, 3])
                    )
                }
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(shape)
    }

    private var ink: ColorToken {
        if !isEnabled { return .ink3 }
        return isPrimary ? .surface : .ink
    }

    private var fill: ColorToken {
        if !isEnabled { return .surfaceSunken }
        return isPrimary ? .ink : .surface
    }
}

extension ButtonStyle where Self == StrideButtonStyle {
    static var stride: StrideButtonStyle { StrideButtonStyle() }
    static var stridePrimary: StrideButtonStyle { StrideButtonStyle(isPrimary: true) }
}
