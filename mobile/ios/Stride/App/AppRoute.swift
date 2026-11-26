/// A screen pushed onto a tab's stack, by the identifier the server gives it.
/// A deep link or a notification names one, and the tab's stack shows it.
enum AppRoute: Hashable, Sendable {
    case task(String)
    case goal(String)
    case board(String)
}
