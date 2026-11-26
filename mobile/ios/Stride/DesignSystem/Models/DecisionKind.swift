import Foundation

/// Why a decision card asks for the reader.
enum DecisionKind: String, CaseIterable, Sendable {
    case review
    case released
    case claimExpired = "claim_expired"
    case hookFailed = "hook_failed"
    case readyEmpty = "ready_empty"

    var label: LocalizedStringResource {
        switch self {
        case .review: .decisionKindReview
        case .released: .decisionKindReleased
        case .claimExpired: .decisionKindClaimExpired
        case .hookFailed: .decisionKindHookFailed
        case .readyEmpty: .decisionKindReadyEmpty
        }
    }

    /// The kind's dot.
    var color: ColorToken {
        switch self {
        case .review: .stReview
        case .released, .claimExpired: .stDoing
        case .hookFailed: .stBlocked
        case .readyEmpty: .stReady
        }
    }
}
