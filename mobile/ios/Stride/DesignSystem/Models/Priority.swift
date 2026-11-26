import Foundation

/// A task's priority, by the API's name for it.
enum Priority: String, CaseIterable, Sendable {
    case low
    case medium
    case high
    case critical

    /// The priority in words, such as "Critical priority", since the dot shows
    /// it by colour alone.
    var label: LocalizedStringResource {
        switch self {
        case .low: .priorityLow
        case .medium: .priorityMedium
        case .high: .priorityHigh
        case .critical: .priorityCritical
        }
    }

    var color: ColorToken {
        switch self {
        case .low: .priLow
        case .medium: .priMedium
        case .high: .priHigh
        case .critical: .priCritical
        }
    }
}
