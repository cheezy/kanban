import Foundation

/// A target's status, by the API's name for it.
enum TargetStatus: String, CaseIterable, Sendable {
    case onTrack = "on_track"
    case atRisk = "at_risk"
    case missed
    case complete

    var label: LocalizedStringResource {
        switch self {
        case .onTrack: .targetStatusOnTrack
        case .atRisk: .targetStatusAtRisk
        case .missed: .targetStatusMissed
        case .complete: .targetStatusComplete
        }
    }

    /// The pill's colours, as the Targets screen draws them.
    var tone: StatusTone {
        switch self {
        case .onTrack: .ready
        case .atRisk: .doing
        case .missed: .blocked
        case .complete: .done
        }
    }
}
