import SwiftUI

/// A goal whose after_goal hook failed, with its exit code and how long it ran.
struct HookFailedCardView: View {
    @Environment(\.locale) private var locale

    let card: NowCard
    let isOffline: Bool
    let perform: (NowAction) -> Void

    var body: some View {
        DecisionCard(card.content) {
            if let line = card.body(in: locale) {
                NowQuote(text: line, isMonospaced: true)
            }
            if !card.buttons.isEmpty {
                NowCardActions(actions: card.buttons, isOffline: isOffline, perform: perform)
            }
        }
    }
}
