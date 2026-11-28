import SwiftUI

/// The notice above the verdicts on a change this device may not approve:
/// "Too large to approve on a phone", the server's file and line counts, and
/// where it can be approved. At the accessibility text sizes the icon sits
/// above the text, so the text keeps the notice's whole width.
struct ReviewLargeNotice: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var locale

    let size: ReviewChangeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
        layout {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(ColorToken.stDoing.color)
                .accessibilityHidden(true)
            // The design's `.notice`: 14-point text in ink, the title at
            // weight 600, and only the icon in st-doing.
            VStack(alignment: .leading, spacing: 4) {
                Text(.reviewQueueTooLargePhone)
                    .fontWeight(.semibold)
                Text(verbatim: size.text(in: locale))
                Text(.reviewLargeHint)
            }
            .textStyle(.subheadline)
            .foregroundStyle(ColorToken.ink.color)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ColorToken.stDoingSoft.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("review-large")
    }
}

#if DEBUG
#Preview("Light") {
    ReviewLargeNotice(size: ReviewChangeSize(files: 14, changedLines: 652))
        .padding()
        .preferredColorScheme(.light)
}

#Preview("Dark, German, largest text") {
    ReviewLargeNotice(size: ReviewChangeSize(files: 14, changedLines: 652))
        .padding()
        .environment(\.locale, Locale(identifier: "de"))
        .dynamicTypeSize(.accessibility5)
        .preferredColorScheme(.dark)
}
#endif
