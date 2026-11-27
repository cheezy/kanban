import SwiftUI

/// A review's verdict on one section, such as "Patterns failed". Its colour
/// says the verdict, and so do its words to VoiceOver; with Differentiate
/// Without Color on, a symbol replaces the dot.
struct VerdictPill: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor

    @ScaledMetric(relativeTo: .caption2) private var dotSide = 6
    @ScaledMetric(relativeTo: .caption2) private var minHeight = 18

    let verdict: Verdict

    var body: some View {
        HStack(spacing: 5) {
            marker
                .accessibilityHidden(true)

            Text(verbatim: verdict.section.name.resolved(in: locale))
                .textStyle(.label)
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(verdict.state.ink.color)
        .padding(.horizontal, 6)
        .frame(minHeight: minHeight)
        .background(verdict.state.fill.color, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: verdict.reading(in: locale)))
        // Read as text, not a control, so the audit does not hold the
        // 18-point pill to a tap target's size.
        .accessibilityAddTraits(.isStaticText)
    }

    @ViewBuilder private var marker: some View {
        if withoutColor {
            Image(systemName: verdict.state.symbol)
                .imageScale(.small)
                .fontWeight(.bold)
        } else {
            Circle()
                .frame(width: dotSide, height: dotSide)
        }
    }
}

#if DEBUG
#Preview("Light") {
    SharedViewSamples.verdicts.preview
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    SharedViewSamples.verdicts.preview
        .preferredColorScheme(.dark)
}

#Preview("German, largest text") {
    SharedViewSamples.verdicts.preview
        .environment(\.locale, Locale(identifier: "de"))
        .dynamicTypeSize(.accessibility5)
}
#endif
