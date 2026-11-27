import SwiftUI

/// Grey cards in the shape of decision cards while the first answer is on its
/// way. The Review queue shows it too, with its own label.
struct NowSkeleton: View {
    var label: LocalizedStringResource = .nowLoading
    var cardHeight: CGFloat = 140
    var identifier = "now-loading"

    var body: some View {
        VStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: DesignTokens.Radius.xl)
                    .fill(ColorToken.surfaceSunken.color)
                    .frame(height: cardHeight)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(identifier)
    }
}

/// Nothing is waiting on the person. The Review queue shows it too, with its
/// own message.
struct NowEmptyState: View {
    var message: LocalizedStringResource = .nowEmpty
    var identifier = "now-empty"

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .textStyle(.largeTitle)
                .foregroundStyle(ColorToken.stDone.color)
                .accessibilityHidden(true)
            Text(message)
                .textStyle(.body)
                .foregroundStyle(ColorToken.ink2.color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

/// Offline before anything was saved on the device: the offline banner's look,
/// with nothing to show under it. The Review queue shows it too.
struct NowNothingSaved: View {
    var identifier = "now-nothing-saved"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "wifi.slash")
                .foregroundStyle(ColorToken.stDoing.color)
                .accessibilityHidden(true)
            Text(.nowOfflineNothing)
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
