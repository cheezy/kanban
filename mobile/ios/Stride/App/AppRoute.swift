/// A screen pushed onto a tab's stack, by the identifier the server gives it.
/// A deep link or a notification names one, and the tab's stack shows it.
enum AppRoute: Hashable, Sendable {
    case task(String)
    /// A task's review, by the task's numeric id, which the review API takes.
    case review(Int)
    case goal(String)
    /// A board, opened on `column` when one is named.
    case board(String, column: BoardColumn? = nil)
}
