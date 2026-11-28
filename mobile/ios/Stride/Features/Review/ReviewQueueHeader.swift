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
                Text(.reviewQueueWaiting(count: waiting))
                    .textStyle(.subheadline)
                    .foregroundStyle(ColorToken.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("review-waiting")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
