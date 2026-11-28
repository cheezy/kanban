import SwiftUI

/// The notice above the verdicts on a change this device may not approve.
struct ReviewLargeNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(.reviewQueueTooLargePhone)
                .textStyle(.callout)
                .fontWeight(.semibold)
            Text(.reviewLargeHint)
                .textStyle(.footnote)
        }
        .foregroundStyle(ColorToken.stDoing.color)
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ColorToken.stDoingSoft.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("review-large")
    }
}
