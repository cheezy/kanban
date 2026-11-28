import SwiftUI

/// The agent on a decision: its small avatar and its name, read as one.
struct DecisionAgentRow: View {
    let agent: AgentAvatarContent

    var body: some View {
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
}
