import Foundation

/// A section of the review screen under its header.
enum ReviewSectionKind: Hashable, Sendable {
    case summary
    case verdicts
    case checks
    case files
}
