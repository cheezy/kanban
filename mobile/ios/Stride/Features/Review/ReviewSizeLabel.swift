import Foundation

/// What a row says about a change too large to approve on a phone.
enum ReviewSizeLabel: Hashable, Sendable {
    /// Large, and this device may still approve it.
    case large
    /// Large, so it is approved on a tablet or the web.
    case tooLargeForPhone

    var text: LocalizedStringResource {
        switch self {
        case .large: .reviewQueueLarge
        case .tooLargeForPhone: .reviewQueueTooLargePhone
        }
    }
}
