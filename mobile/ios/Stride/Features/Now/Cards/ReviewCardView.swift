import SwiftUI

/// A task waiting for the person's review: its agent, verdicts and first
/// failed note, then Open review. Approving happens on the review screen.
struct ReviewCardView: View {
    let card: NowCard
    let isOffline: Bool
    let perform: (NowAction) -> Void

    var body: some View {
        DecisionCard(card.content) {
            if !card.buttons.isEmpty {
                NowCardActions(actions: card.buttons, isOffline: isOffline, perform: perform)
            }
        }
    }
}
