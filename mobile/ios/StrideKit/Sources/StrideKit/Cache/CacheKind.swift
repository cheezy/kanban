import Foundation

/// What the cache keeps, where, and how many of each.
enum CacheKind: String, Sendable, CaseIterable {
    /// The decisions list, which the widget reads for its count.
    case decisions
    /// The reviews opened, the last `Cache.openedLimit` of them.
    case review
    /// A review's file with its highlighted diff, kept as long as its review is.
    case reviewFile = "review-file"

    /// How many entries of the kind are kept, or nil when the kind has one entry
    /// or goes with its parent.
    var limit: Int? {
        switch self {
        case .review: Cache.openedLimit
        case .decisions, .reviewFile: nil
        }
    }

    var store: CacheStore {
        switch self {
        case .decisions: .afterFirstUnlock
        case .review, .reviewFile: .whileUnlocked
        }
    }
}
