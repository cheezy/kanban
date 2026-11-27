import Foundation
import Observation
import StrideKit

/// Where the shell is: the selected tab, each tab's stack of pushed screens,
/// the sheet a corner button opened, and the two things the shell shows of
/// the person, the avatar's name and the Now badge.
@MainActor
@Observable
final class AppRouter {
    private(set) var selectedTab: AppTab = .now

    /// Each tab's stack, kept while another tab is selected.
    var paths = TabPaths()

    var sheet: ShellSheet?

    /// The signed-in person, for the avatar. Nil until `/api/me` answers.
    private(set) var person: AgentAvatarContent?

    /// Everything waiting on the person, from `/api/me/decisions`.
    private(set) var waitingCount = 0

    @ObservationIgnored private let api: (any StrideAPI)?

    /// The live updates, which connect again each time the app comes back.
    @ObservationIgnored private let live: LiveChannel?

    /// Bumped by every sign-out, so an answer that set out before one is dropped.
    @ObservationIgnored private var session = 0

    init(api: (any StrideAPI)?, live: LiveChannel? = nil) {
        self.api = api
        self.live = live
    }

    // MARK: Tabs

    /// Selects `tab`. Selecting the tab already selected takes it back to its
    /// first screen, as a second tap on a tab does on iOS; the other tabs keep
    /// their stacks.
    func select(_ tab: AppTab) {
        if tab == selectedTab {
            paths[tab] = []
        } else {
            selectedTab = tab
        }
    }

    /// Pushes `route` onto `tab`'s stack without leaving the selected tab.
    func push(_ route: AppRoute, on tab: AppTab) {
        paths[tab].append(route)
    }

    /// Opens `route` on `tab` from its first screen, as a deep link does.
    func show(_ route: AppRoute, on tab: AppTab) {
        selectedTab = tab
        paths[tab] = [route]
    }

    /// The count a tab's badge shows, where zero hides it. Only Now has one.
    func badge(for tab: AppTab) -> Int {
        tab == .now ? waitingCount : 0
    }

    // MARK: Corner buttons

    func showNewTask() {
        sheet = .newTask
    }

    func showSettings() {
        sheet = .settings
    }

    // MARK: Signing in and out

    /// Keeps the shell only while the shell is the screen. Any other screen
    /// clears everything the person saw, so a sign-out leaves nothing behind.
    func follow(_ screen: RootScreen) {
        guard screen != .shell else { return }

        session += 1
        selectedTab = .now
        paths = TabPaths()
        sheet = nil
        person = nil
        waitingCount = 0
        // The live channels drop the last person's state too.
        let live = live
        Task { await live?.forget() }
    }

    /// Asks the server for the person's name and how much waits on them, and
    /// connects the live updates again so each channel sends its full state. A
    /// failed answer leaves what the shell already shows.
    func refresh() async {
        await live?.resume()
        guard let api else { return }

        let asked = session
        async let me = Self.person(using: api)
        async let waiting = Self.waitingCount(using: api)
        let (person, count) = await (me, waiting)
        guard asked == session else { return }

        if let person { self.person = person }
        if let count { waitingCount = count }
    }

    private nonisolated static func person(using api: any StrideAPI) async -> AgentAvatarContent? {
        guard
            case .ok(let response) = try? await api.getMe(),
            let me = try? response.body.json.data
        else { return nil }

        return AgentAvatarContent(name: me.user.displayName, isPerson: true)
    }

    private nonisolated static func waitingCount(using api: any StrideAPI) async -> Int? {
        guard
            case .ok(let response) = try? await api.listMyDecisions(),
            let list = try? response.body.json.data
        else { return nil }

        return max(0, list.summary.waiting)
    }
}
