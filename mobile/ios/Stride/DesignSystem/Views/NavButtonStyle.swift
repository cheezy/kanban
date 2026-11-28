import SwiftUI

/// The design's `.navbtn`: a sheet's Cancel or Send, stride-orange-ink at the
/// headline size and at least 44 points square. Off, it reads in ink-3, as
/// `.navbtn[disabled]` does. Unlike `.plain`, it never fades a disabled
/// label, which the accessibility audit fails for contrast (W2800).
struct NavButtonStyle: ButtonStyle {
    var weight: Font.Weight = .regular

    func makeBody(configuration: Configuration) -> some View {
        NavButtonLabel(configuration: configuration, weight: weight)
    }
}

private struct NavButtonLabel: View {
    @Environment(\.isEnabled) private var isEnabled

    let configuration: ButtonStyleConfiguration
    let weight: Font.Weight

    var body: some View {
        configuration.label
            .textStyle(.headline)
            .fontWeight(weight)
            .foregroundStyle((isEnabled ? ColorToken.strideOrangeInk : .ink3).color)
            .frame(minWidth: 44, minHeight: 44)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}
