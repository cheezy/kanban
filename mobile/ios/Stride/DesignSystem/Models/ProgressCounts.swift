import Foundation

/// How a goal's tasks stand, as a progress bar shows them. Counts below zero
/// are read as zero, and the parts never add up to more than the total.
struct ProgressCounts: Hashable, Sendable {
    let total: Int
    let done: Int
    let review: Int
    let doing: Int
    let blocked: Int

    init(total: Int, done: Int = 0, review: Int = 0, doing: Int = 0, blocked: Int = 0) {
        let total = max(0, total)
        let done = min(max(0, done), total)
        let review = min(max(0, review), total - done)
        let doing = min(max(0, doing), total - done - review)

        self.total = total
        self.done = done
        self.review = review
        self.doing = doing
        self.blocked = min(max(0, blocked), total - done - review - doing)
    }

    /// The tasks not yet started.
    var toDo: Int { total - done - review - doing - blocked }

    /// The bar's parts, in the order it draws them.
    var segments: [ProgressSegment] {
        [
            ProgressSegment(kind: .done, count: done),
            ProgressSegment(kind: .review, count: review),
            ProgressSegment(kind: .doing, count: doing),
            ProgressSegment(kind: .blocked, count: blocked),
            ProgressSegment(kind: .toDo, count: toDo),
        ]
        .filter { $0.count > 0 }
    }

    /// The counts in words, such as "4 of 9 done, 1 in review, 2 in
    /// progress", or "No tasks yet" for a goal with none.
    func reading(in locale: Locale) -> String {
        guard total > 0 else { return LocalizedStringResource.progressNoTasks.resolved(in: locale) }

        let rest: [LocalizedStringResource] = [
            review > 0 ? .progressInReview(count: review) : nil,
            doing > 0 ? .progressInProgress(count: doing) : nil,
            blocked > 0 ? .progressBlocked(count: blocked) : nil,
        ]
        .compactMap { $0 }
        let parts = ([.progressDone(done: done, count: total)] + rest).map { $0.resolved(in: locale) }

        return parts.formatted(.list(type: .and, width: .narrow).locale(locale))
    }
}
