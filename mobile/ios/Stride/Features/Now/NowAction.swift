import Foundation
import StrideKit

/// A button a Now card shows, from the actions the server offers. Approving
/// and requesting changes happen on the review screen, never on a card.
enum NowAction: CaseIterable, Sendable {
    case openReview
    case reply
    case moveToBacklog
    case viewAttempt
    case openOnWeb
    case openBacklog

    /// Nil for an action a card does not show, and for one this build does
    /// not know.
    init?(_ action: Components.Schemas.DecisionItem.ActionsPayloadPayload) {
        switch action.value1 {
        case .openReview: self = .openReview
        case .reply: self = .reply
        case .moveToBacklog: self = .moveToBacklog
        case .viewAttempt: self = .viewAttempt
        case .openOnWeb: self = .openOnWeb
        case .openBacklog: self = .openBacklog
        case .approve, .requestChanges, nil: return nil
        }
    }

    /// The button's title. Opening the backlog is the whole Ready card, which
    /// says it in its own words.
    var label: LocalizedStringResource {
        switch self {
        case .openReview: .nowOpenReview
        case .reply: .nowReply
        case .moveToBacklog: .nowMoveToBacklog
        case .viewAttempt: .nowViewAttempt
        case .openOnWeb: .nowOpenOnWeb
        case .openBacklog: .decisionKindReadyEmpty
        }
    }

    /// Only opening a review is the card's main step.
    var isPrimary: Bool { self == .openReview }
}
