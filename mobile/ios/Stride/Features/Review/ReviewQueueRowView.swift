import SwiftUI

/// One pending review: its identifier, priority and age, its title, what it
/// holds up, its size, its agent, the first failed note and its verdicts.
/// The server's text is shown as plain text.
struct ReviewQueueRowView: View {
    let row: ReviewQueueRow

    private var content: DecisionCardContent { row.content }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                DecisionIdentifier(identifier: content.identifier)
                if let priority = content.priority {
                    PriorityDot(priority: priority)
                }
                Spacer(minLength: 8)
                if content.since != nil {
                    DecisionAge(content: content)
                }
            }

            Text(verbatim: content.title)
                .textStyle(.callout)
                .foregroundStyle(ColorToken.ink.color)
                .fixedSize(horizontal: false, vertical: true)

            if content.holdsUp > 0 || row.sizeLabel != nil || row.files != nil {
                FlowLayout(spacing: 8) {
                    if content.holdsUp > 0 {
                        StatusPill(.decisionHoldsUp(count: content.holdsUp), tone: .blocked)
                    }
                    if let label = row.sizeLabel {
                        StatusPill(label.text, tone: .doing)
                            .accessibilityIdentifier("review-size-label")
                    }
                    if let files = row.files {
                        Text(.reviewQueueFiles(count: files))
                            .textStyle(.footnote)
                            .foregroundStyle(ColorToken.ink2.color)
                    }
                }
            }

            if let agent = content.agent {
                DecisionAgentRow(agent: agent)
            }

            if let issue = content.issue {
                Text(verbatim: issue)
                    .textStyle(.footnote)
                    .foregroundStyle(ColorToken.stBlocked.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !content.verdicts.isEmpty {
                VerdictFlow(verdicts: content.verdicts)
            }
        }
        // No accessibility container of its own: inside the queue's link its
        // parts read as one button. iOS 18's audit reported an identified
        // container with no label as missing a description (W2797).
        .cardChrome()
    }
}
