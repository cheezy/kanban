import SwiftUI

/// A task an agent gave back, with the agent's reason quoted after its avatar.
struct ReleasedCardView: View {
    @Environment(\.locale) private var locale

    let card: NowCard
    let isOffline: Bool
    let perform: (NowAction) -> Void

    var body: some View {
        DecisionCard(card.content) {
            if let reason = card.body(in: locale) {
                NowQuote(text: reason, agent: agent)
            }
            if !card.buttons.isEmpty {
                NowCardActions(actions: card.buttons, isOffline: isOffline, perform: perform)
            }
        }
    }

    private var agent: AgentAvatarContent? {
        guard case .released(_, let agent) = card.detail else { return nil }

        return agent
    }
}
