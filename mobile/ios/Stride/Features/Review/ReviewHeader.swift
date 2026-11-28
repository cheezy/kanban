import SwiftUI

/// The identifier, priority, what it holds up, the title, and the agent,
/// time and goal.
struct ReviewHeader: View {
    @Environment(\.locale) private var locale

    let content: ReviewContent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 8) {
                DecisionIdentifier(identifier: content.identifier)
                if let priority = content.priority {
                    PriorityDot(priority: priority)
                }
                StatusPill(.decisionKindReview, tone: .review)
                if let holdsUp = content.holdsUpLabel(in: locale) {
                    StatusPill(holdsUp, tone: .blocked)
                }
            }

            Text(verbatim: content.title)
                .textStyle(.title)
                .foregroundStyle(ColorToken.ink.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("review-title")

            if let details = content.details(in: locale) {
                HStack(alignment: .top, spacing: 8) {
                    if let agent = content.agent {
                        AgentAvatar(agent, size: .small)
                            .accessibilityHidden(true)
                    }
                    Text(verbatim: details)
                        .textStyle(.footnote)
                        .foregroundStyle(ColorToken.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                // The UI tests find the agent and details line by this.
                .accessibilityIdentifier("review-details")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
