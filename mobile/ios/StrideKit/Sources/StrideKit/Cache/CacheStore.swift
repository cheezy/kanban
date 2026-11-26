import Foundation

/// The cache's two files, one for each Data Protection class.
///
/// The widget reads the decisions count while the phone is locked, so that list
/// is readable from the first unlock after a restart, as the design's section
/// 9.3 says. Everything else, such as review diffs with their code, is readable
/// only while the phone is unlocked.
enum CacheStore: String, Sendable, CaseIterable {
    case afterFirstUnlock = "AfterFirstUnlock"
    case whileUnlocked = "WhileUnlocked"

    var protection: FileProtectionType {
        switch self {
        case .afterFirstUnlock: .completeUntilFirstUserAuthentication
        case .whileUnlocked: .complete
        }
    }
}
