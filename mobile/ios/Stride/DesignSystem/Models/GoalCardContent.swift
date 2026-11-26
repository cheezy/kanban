/// What a goal card shows. The identifier and title come from the server.
struct GoalCardContent: Hashable, Sendable {
    let identifier: String
    let title: String
    let progress: ProgressCounts
    let waitingOnYou: Int
    let hookFailed: Bool

    init(identifier: String, title: String, progress: ProgressCounts, waitingOnYou: Int = 0, hookFailed: Bool = false) {
        self.identifier = identifier
        self.title = title
        self.progress = progress
        self.waitingOnYou = max(0, waitingOnYou)
        self.hookFailed = hookFailed
    }
}
