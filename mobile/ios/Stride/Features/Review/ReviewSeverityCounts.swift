import Foundation

/// How many security issues the reviewer reported at each severity.
struct ReviewSeverityCounts: Hashable, Sendable {
    let critical: Int
    let important: Int
    let minor: Int

    var total: Int { critical + important + minor }
}
