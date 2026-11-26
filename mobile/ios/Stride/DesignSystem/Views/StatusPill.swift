import SwiftUI

/// A short state in words on its soft status colour, such as a target's
/// "At risk". The text says the state, so nothing rests on the colour alone.
struct StatusPill: View {
    @Environment(\.locale) private var locale

    @ScaledMetric(relativeTo: .footnote) private var minHeight = 20

    let label: LocalizedStringResource
    let tone: StatusTone

    init(_ label: LocalizedStringResource, tone: StatusTone) {
        self.label = label
        self.tone = tone
    }

    init(_ status: TargetStatus) {
        self.init(status.label, tone: status.tone)
    }

    var body: some View {
        // The design's pill is 11.5 points at weight 600; footnote is the
        // nearest token style, made semibold.
        Text(verbatim: label.resolved(in: locale))
            .textStyle(.footnote)
            .fontWeight(.semibold)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(tone.ink.color)
            .padding(.horizontal, 7)
            .frame(minHeight: minHeight)
            .background(tone.fill.color, in: Capsule())
    }
}

#if DEBUG
#Preview("Light") {
    SharedViewSamples.statuses.preview
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    SharedViewSamples.statuses.preview
        .preferredColorScheme(.dark)
}

#Preview("German, largest text") {
    SharedViewSamples.statuses.preview
        .environment(\.locale, Locale(identifier: "de"))
        .dynamicTypeSize(.accessibility5)
}
#endif
