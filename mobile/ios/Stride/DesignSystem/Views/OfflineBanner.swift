import SwiftUI

/// Says the app is offline and when the data it shows was fetched.
struct OfflineBanner: View {
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    let content: OfflineBannerContent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "wifi.slash")
                .foregroundStyle(ColorToken.stDoing.color)
                .accessibilityHidden(true)

            Text(verbatim: content.message(in: locale, timeZone: timeZone))
                .textStyle(.subheadline)
                .foregroundStyle(ColorToken.ink.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(ColorToken.stDoingSoft.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("Light") {
    SharedViewSamples.offline.preview
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    SharedViewSamples.offline.preview
        .preferredColorScheme(.dark)
}

#Preview("German, largest text") {
    SharedViewSamples.offline.preview
        .environment(\.locale, Locale(identifier: "de"))
        .dynamicTypeSize(.accessibility5)
}
#endif
