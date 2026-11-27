import Foundation
import Observation
import StrideKit

/// Where the shell is: the selected tab, each tab's stack of pushed screens,
/// the sheet a corner button opened, the avatar's name, the Now screen's
/// decisions, whose waiting count is the Now badge, and the Review queue.
@MainActor
@Observable
final class AppRouter {
    private(set) var selectedTab: AppTab = .now

    /// Each tab's stack, kept while another tab is selected.
    var paths = TabPaths()

    var sheet: ShellSheet?

    /// The signed-in person, for the avatar. Nil until `/api/me` answers.
    private(set) var person: AgentAvatarContent?

    /// The Now screen's decisions, whose waiting count is the Now badge.
    let now: NowModel

    /// The Now cards' buttons, with their sheets and notices.
    let nowActions: NowActions

    /// The Review tab's queue of pending reviews.
    let reviews: ReviewQueueModel

    @ObservationIgnored private let api: (any StrideAPI)?
    @ObservationIgnored private let cache: Cache?
    @ObservationIgnored private let connectivity: Connectivity

    /// The live updates, which connect again each time the app comes back.
    @ObservationIgnored private let live: LiveChannel?

    /// Bumped by every sign-out, so an answer that set out before one is dropped.
    @ObservationIgnored private var session = 0

    init(
        api: (any StrideAPI)?,
        live: LiveChannel? = nil,
        cache: Cache? = nil,
        connectivity: Connectivity = .system
    ) {
        self.api = api
        self.live = live
        self.cache = cache
        self.connectivity = connectivity
        now = NowModel(api: api, cache: cache, live: live, connectivity: connectivity)
        nowActions = NowActions(api: api, now: now)
        reviews = ReviewQueueModel(api: api, cache: cache, live: live, connectivity: connectivity)
    }

    /// The model for one review's screen, which reads the same API and cache
    /// as the queue.
    func reviewModel(for taskID: Int) -> ReviewModel {
        ReviewModel(taskID: taskID, api: api, cache: cache, connectivity: connectivity)
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
        tab == .now ? now.summary.waiting : 0
    }

    // MARK: Corner buttons

    /// Follows a Now card's action: pushes or opens its screen, and returns
    /// the address of a web page for the caller to open.
    func open(_ destination: NowDestination) -> URL? {
        switch destination {
        case .push(let route):
            push(route, on: .now)
            return nil
        case .show(let route, let tab):
            show(route, on: tab)
            return nil
        case .web(let url):
            return url
        }
    }

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
        now.forget()
        nowActions.forget()
        reviews.forget()
        // The live channels drop the last person's state too.
        let live = live
        Task { await live?.forget() }
    }

    /// Asks the server for the person's name, how much waits on them and the
    /// reviews in their queue, and
    /// connects the live updates again so each channel sends its full state. A
    /// failed answer leaves what the shell already shows.
    func refresh() async {
        await live?.resume()
        guard let api else { return }

        let asked = session
        async let me = Self.person(using: api)
        async let queue: Void = reviews.load()
        await now.load()
        await queue
        let person = await me
        guard asked == session else { return }

        if let person { self.person = person }
    }

    private nonisolated static func person(using api: any StrideAPI) async -> AgentAvatarContent? {
        guard
            case .ok(let response) = try? await api.getMe(),
            let me = try? response.body.json.data
        else { return nil }

        return AgentAvatarContent(name: me.user.displayName, isPerson: true)
    }

}
