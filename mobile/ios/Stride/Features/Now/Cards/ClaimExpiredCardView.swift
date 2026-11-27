import SwiftUI

/// A task whose claim ran out, saying who held it and for how long.
struct ClaimExpiredCardView: View {
    @Environment(\.locale) private var locale

    let card: NowCard
    let isOffline: Bool
    let perform: (NowAction) -> Void

    var body: some View {
        DecisionCard(card.content) {
            if let sentence = card.body(in: locale) {
                Text(verbatim: sentence)
                    .textStyle(.subheadline)
                    .foregroundStyle(ColorToken.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !card.buttons.isEmpty {
                NowCardActions(actions: card.buttons, isOffline: isOffline, perform: perform)
            }
        }
    }
}
