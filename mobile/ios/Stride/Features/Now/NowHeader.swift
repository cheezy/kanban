import SwiftUI

/// Now's title, what waits and what it holds up, and how many agents are
/// working. The counts sit under the title at the accessibility text sizes.
struct NowHeader: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale

    @ScaledMetric(relativeTo: .footnote) private var liveDotSide = 7

    let summary: NowSummary

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .lastTextBaseline, spacing: 12))

        layout {
            VStack(alignment: .leading, spacing: 4) {
                Text(.tabNow)
                    .textStyle(.largeTitle)
                    .foregroundStyle(ColorToken.ink.color)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("tab-title")
                subtitle
                    .textStyle(.subheadline)
                    .foregroundStyle(ColorToken.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if summary.agentsWorking > 0 {
                HStack(spacing: 5) {
                    Circle()
                        .fill(ColorToken.stDone.color)
                        .frame(width: liveDotSide, height: liveDotSide)
                        .accessibilityHidden(true)
                    Text(.nowAgentsWorking(count: summary.agentsWorking))
                        .textStyle(.footnote)
                        .fontWeight(.semibold)
                        .foregroundStyle(ColorToken.stDone.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// "5 waiting on you · 6 tasks held up", without the second part when
    /// nothing is held up.
    private var subtitle: Text {
        let waiting = Text(.goalWaitingOnYou(count: summary.waiting))
        guard summary.heldUp > 0 else { return waiting }

        // The parts are this view's own strings, joined in the locale's order.
        return Text(.nowHeaderSummary(
            waiting: LocalizedStringResource.goalWaitingOnYou(count: summary.waiting).resolved(in: locale),
            heldUp: LocalizedStringResource.nowHeldUp(count: summary.heldUp).resolved(in: locale)
        ))
    }
}
