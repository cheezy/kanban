import Foundation

/// Where a Now card's action goes: a screen pushed on Now, a tab opened at a
/// screen, or a page on the web.
enum NowDestination: Hashable, Sendable {
    case push(AppRoute)
    case show(AppRoute, on: AppTab)
    case web(URL)
}
