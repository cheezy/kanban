import SwiftUI

/// A task waiting on the reader: why it waits, what it holds up, its
/// identifier, priority, title, agent, problem and verdicts, and the actions
/// the screen puts below. The server's text is shown as plain text.
struct DecisionCard<Actions: View>: View {
    @Environment(\.locale) private var locale

    @ScaledMetric(relativeTo: .caption2) private var kindDotSide = 7

    let content: DecisionCardContent
    let actions: Actions

    init(_ content: DecisionCardContent, @ViewBuilder actions: () -> Actions) {
        self.content = content
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                FlowLayout(spacing: 8) {
                    kind
                    if content.holdsUp > 0 {
                        StatusPill(.decisionHoldsUp(count: content.holdsUp), tone: .blocked)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if content.since != nil {
                    age
                }
            }

            HStack(spacing: 8) {
                Text(verbatim: content.identifier)
                    .textStyle(.code)
                    .foregroundStyle(ColorToken.ink3.color)
                    .accessibilityIdentifier("card-identifier")
                if let priority = content.priority {
                    PriorityDot(priority: priority)
                }
            }

            Text(verbatim: content.title)
                .textStyle(.callout)
                .foregroundStyle(ColorToken.ink.color)
                .fixedSize(horizontal: false, vertical: true)

            if let agent = content.agent {
                HStack(alignment: .top, spacing: 8) {
                    AgentAvatar(agent, size: .small)
                        .accessibilityHidden(true)
                    Text(verbatim: agent.name)
                        .textStyle(.footnote)
                        .foregroundStyle(ColorToken.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }

            if let issue = content.issue {
                Text(verbatim: issue)
                    .textStyle(.footnote)
                    .foregroundStyle(ColorToken.stBlocked.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !content.verdicts.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(content.verdicts, id: \.self) { VerdictPill(verdict: $0) }
                }
            }

            actions
        }
        .cardChrome()
        .accessibilityElement(children: .contain)
    }

    /// The age, redrawn each minute.
    private var age: some View {
        TimelineView(.everyMinute) { context in
            Text(verbatim: content.age(at: context.date, in: locale) ?? "")
                .textStyle(.code)
                .foregroundStyle(ColorToken.ink3.color)
                .accessibilityLabel(Text(verbatim: content.age(at: context.date, in: locale, width: .wide) ?? ""))
                .accessibilityIdentifier("card-age")
        }
    }

    private var kind: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(content.kind.color.color)
                .frame(width: kindDotSide, height: kindDotSide)
                .accessibilityHidden(true)
            Text(verbatim: content.kind.label.resolved(in: locale))
                .textStyle(.label)
                .foregroundStyle(ColorToken.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

extension DecisionCard where Actions == EmptyView {
    init(_ content: DecisionCardContent) {
        self.init(content) { EmptyView() }
    }
}

#if DEBUG
#Preview("Light") {
    SharedViewSamples.decision.preview
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    SharedViewSamples.decision.preview
        .preferredColorScheme(.dark)
}

#Preview("German, largest text") {
    SharedViewSamples.decision.preview
        .environment(\.locale, Locale(identifier: "de"))
        .dynamicTypeSize(.accessibility5)
}
#endif
