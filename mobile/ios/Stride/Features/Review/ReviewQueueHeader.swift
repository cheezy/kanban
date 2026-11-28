import SwiftUI

/// The tab's title, and how many reviews wait once the queue has loaded.
struct ReviewQueueHeader: View {
    let waiting: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(.tabReview)
                .textStyle(.largeTitle)
                .foregroundStyle(ColorToken.ink.color)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("tab-title")
            if let waiting {
                // "3 waiting on you", as the Now header says it. The iOS 26
                // audit on an iPad failed the contrast of the short "3
                // waiting" in ink-2 and ink-3 alike, and passes the Now
                // header's longer line in the same style (W2800).
                Text(.goalWaitingOnYou(count: waiting))
                    .textStyle(.subheadline)
                    .foregroundStyle(ColorToken.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("review-waiting")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
