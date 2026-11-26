/// A status colour pair: the soft fill of a pill and the ink of its text.
enum StatusTone: CaseIterable, Sendable {
    case backlog
    case ready
    case doing
    case review
    case done
    case blocked

    var ink: ColorToken {
        switch self {
        case .backlog: .stBacklog
        case .ready: .stReady
        case .doing: .stDoing
        case .review: .stReview
        case .done: .stDone
        case .blocked: .stBlocked
        }
    }

    var fill: ColorToken {
        switch self {
        case .backlog: .stBacklogSoft
        case .ready: .stReadySoft
        case .doing: .stDoingSoft
        case .review: .stReviewSoft
        case .done: .stDoneSoft
        case .blocked: .stBlockedSoft
        }
    }
}
