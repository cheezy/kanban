import SwiftUI

/// One line of the View attempt sheet: a name on the left and its value on
/// the right, and one above the other at the accessibility text sizes.
struct HookAttemptRow: View {
    let name: LocalizedStringResource
    let value: String

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))

        layout {
            Text(name)
                .textStyle(.subheadline)
                .foregroundStyle(ColorToken.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: stacked ? nil : .infinity, alignment: .leading)
            Text(verbatim: value)
                .textStyle(.code)
                .foregroundStyle(ColorToken.ink.color)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("attempt-row")
    }
}
