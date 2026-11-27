import Foundation

/// The Now screen's filter: everything, the reviews, the problems an agent hit,
/// or the boards whose Ready column is empty.
enum NowFilter: CaseIterable, Identifiable, Sendable {
    case all
    case reviews
    case problems
    case ready

    var id: Self { self }

    var label: LocalizedStringResource {
        switch self {
        case .all: .nowFilterAll
        case .reviews: .nowFilterReviews
        case .problems: .nowFilterProblems
        case .ready: .nowFilterReady
        }
    }

    func includes(_ kind: DecisionKind) -> Bool {
        switch self {
        case .all: true
        case .reviews: kind == .review
        case .problems: [.released, .claimExpired, .hookFailed].contains(kind)
        case .ready: kind == .readyEmpty
        }
    }
}
