import SwiftUI

/// The card for a decision's kind.
struct NowCardView: View {
    let card: NowCard
    let isOffline: Bool
    let perform: (NowAction) -> Void

    var body: some View {
        switch card.detail {
        case .review:
            ReviewCardView(card: card, isOffline: isOffline, perform: perform)
        case .released:
            ReleasedCardView(card: card, isOffline: isOffline, perform: perform)
        case .claimExpired:
            ClaimExpiredCardView(card: card, isOffline: isOffline, perform: perform)
        case .hookFailed:
            HookFailedCardView(card: card, isOffline: isOffline, perform: perform)
        case .readyEmpty:
            // Opening a board needs no connection once it is cached, but
            // nothing is cached yet, so it waits too.
            let canOpen = card.actions.contains(.openBacklog)
            ReadyEmptyCardView(card: card, open: canOpen ? { perform(.openBacklog) } : nil, isOffline: isOffline)
        }
    }
}
