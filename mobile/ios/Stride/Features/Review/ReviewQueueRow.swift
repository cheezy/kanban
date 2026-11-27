import Foundation
import StrideKit

/// One pending review in the Review tab's queue, made from the server's item:
/// the shared card's content, and the size of the change.
struct ReviewQueueRow: Identifiable, Hashable, Sendable {
    typealias Item = Components.Schemas.DecisionItem

    let id: String
    let taskID: Int?
    /// The identifier, title, priority, age, what it holds up and the verdicts.
    let content: DecisionCardContent
    /// How many files changed, or nil when the server could not count them.
    let files: Int?
    let sizeLabel: ReviewSizeLabel?

    /// Nil for an item that is not a review.
    init?(_ item: Item) {
        guard item.kind.value1.flatMap({ DecisionKind(rawValue: $0.rawValue) }) == .review else { return nil }

        let summary = item.summary
        let review = item.details.value1
        id = item.id
        taskID = item.taskId
        content = DecisionCardContent(
            kind: .review,
            identifier: summary.identifier ?? "",
            title: summary.title ?? "",
            priority: summary.priority?.value1.flatMap { Priority(rawValue: $0.rawValue) },
            holdsUp: item.holdsUp ?? 0,
            agent: summary.agent.map { AgentAvatarContent(name: $0) },
            issue: review?.firstFailedNote,
            verdicts: review.map { NowCard.verdicts($0.verdicts) } ?? [],
            since: item.since
        )

        let size = review?.size
        files = size.flatMap { $0.filesUnknown ? nil : max(0, $0.files) }
        sizeLabel = Self.sizeLabel(large: size?.largeChange == true, actions: item.actions)
    }

    /// A large change says so. The server leaves Approve out of a large
    /// change's actions on a phone but still offers Request changes, so a
    /// row that offers the one without the other says where to approve it.
    private static func sizeLabel(large: Bool, actions: [Item.ActionsPayloadPayload]) -> ReviewSizeLabel? {
        guard large else { return nil }

        let offered = Set(actions.compactMap(\.value1))
        if offered.contains(.requestChanges), !offered.contains(.approve) { return .tooLargeForPhone }
        return .large
    }
}

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
