import SwiftUI

/// Offline before anything was saved on the device: the offline banner's look,
/// with nothing to show under it. Each screen passes its own message and
/// identifier.
struct NothingSavedView: View {
    let message: LocalizedStringResource
    let identifier: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "wifi.slash")
                .foregroundStyle(ColorToken.stDoing.color)
                .accessibilityHidden(true)
            Text(message)
                .textStyle(.subheadline)
                .foregroundStyle(ColorToken.ink.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(ColorToken.stDoingSoft.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}
