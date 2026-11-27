import SwiftUI

/// Grey cards in the shape of decision cards while the first answer is on its way.
struct NowSkeleton: View {
    var body: some View {
        VStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: DesignTokens.Radius.xl)
                    .fill(ColorToken.surfaceSunken.color)
                    .frame(height: 140)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(.nowLoading))
        .accessibilityIdentifier("now-loading")
    }
}

/// Nothing is waiting on the person.
struct NowEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .textStyle(.largeTitle)
                .foregroundStyle(ColorToken.stDone.color)
                .accessibilityHidden(true)
            Text(.nowEmpty)
                .textStyle(.body)
                .foregroundStyle(ColorToken.ink2.color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("now-empty")
    }
}

/// Offline before anything was saved on the device: the offline banner's look,
/// with nothing to show under it.
struct NowNothingSaved: View {
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
        .accessibilityIdentifier("now-nothing-saved")
    }
}
