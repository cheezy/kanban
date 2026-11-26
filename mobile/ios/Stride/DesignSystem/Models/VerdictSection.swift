import Foundation

/// The part of a review a verdict is about, by the API's name for it.
enum VerdictSection: String, CaseIterable, Sendable {
    case acceptanceCriteria = "acceptance_criteria"
    case testingStrategy = "testing_strategy"
    case patterns
    case pitfalls
    case securityConsiderations = "security_considerations"

    /// The section's short name, as the web's review shows it.
    var name: LocalizedStringResource {
        switch self {
        case .acceptanceCriteria: .verdictSectionAcceptanceCriteria
        case .testingStrategy: .verdictSectionTestingStrategy
        case .patterns: .verdictSectionPatterns
        case .pitfalls: .verdictSectionPitfalls
        case .securityConsiderations: .verdictSectionSecurityConsiderations
        }
    }
}
