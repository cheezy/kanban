import SwiftUI

/// A label on the left and its result on the right, stacked under it at
/// the accessibility text sizes.
struct ReviewResultRow<Result: View>: View {
    let label: LocalizedStringResource
    @ViewBuilder let result: Result

    @Environment(\.dynamicTypeSize) private var typeSize

    /// Side by side, with the label wrapping first, and stacked at the
    /// accessibility sizes. The choice follows the text size rather than
    /// what fits, so the row does not swap layouts while the text grows.
    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        layout {
            name
                .frame(maxWidth: stacked ? nil : .infinity, alignment: .leading)
            result
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var name: some View {
        Text(label)
            .textStyle(.callout)
            .foregroundStyle(ColorToken.ink.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
