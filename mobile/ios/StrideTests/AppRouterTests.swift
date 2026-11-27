import Foundation
import os
import Testing

@testable import Stride
@testable import StrideKit

/// Which screen the app shows, and how the shell's tabs, stacks and badge move.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppRouterTests {
    private static let storeURL = URL(string: "https://apps.apple.com/app/stride")!

    @Test(
        "signed out shows Sign in",
        arguments: [
            SignInPhase.signedOut(nil), .signedOut(.network), .signedOut(.failed), .signingIn, .locked,
        ]
    )
    func signedOutShowsSignIn(phase: SignInPhase) {
        #expect(RootScreen(storeURL: nil, phase: phase) == .signIn)
        #expect(RootScreen(storeURL: Self.storeURL, phase: phase) == .updateRequired(Self.storeURL))
    }

    @Test("the shell shows only once the plan includes the app or the server could not say")
    func shellNeedsAccess() {
        #expect(RootScreen(storeURL: nil, phase: .starting) == .waiting)
        #expect(RootScreen(storeURL: nil, phase: .signedIn(.checking)) == .waiting)
        #expect(RootScreen(storeURL: nil, phase: .signedIn(.unlocked)) == .shell)
        #expect(RootScreen(storeURL: nil, phase: .signedIn(.unknown)) == .shell)
        #expect(RootScreen(storeURL: nil, phase: .signedIn(.locked)) == .signIn)
        #expect(RootScreen(storeURL: Self.storeURL, phase: .signedIn(.unlocked)) == .updateRequired(Self.storeURL))
    }

    @Test("selecting a tab resets its stack")
    func selectingResetsStack() {
        let router = AppRouter(api: nil)
        router.push(.task("W1"), on: .now)
        router.push(.task("W2"), on: .now)

        router.select(.now)

        #expect(router.selectedTab == .now)
        #expect(router.paths[.now] == [])
    }

    @Test("switching tabs keeps each tab's stack")
    func switchingKeepsStacks() {
        let router = AppRouter(api: nil)
        router.push(.goal("G1"), on: .now)

        router.select(.boards)
        #expect(router.selectedTab == .boards)
        #expect(router.paths[.now] == [.goal("G1")])

        router.select(.now)
        #expect(router.paths[.now] == [.goal("G1")])
    }

    @Test("a route pushed on a background tab waits there")
    func pushOnBackgroundTab() {
        let router = AppRouter(api: nil)
        router.push(.board("7"), on: .boards)

        #expect(router.selectedTab == .now)
        #expect(router.paths[.boards] == [.board("7")])
        #expect(router.paths[.now].isEmpty)
    }

    @Test("a deep link opens its tab from the first screen")
    func showOpensTab() {
        let router = AppRouter(api: nil)
        router.push(.task("W1"), on: .review)

        router.show(.task("W9"), on: .review)

        #expect(router.selectedTab == .review)
        #expect(router.paths[.review] == [.task("W9")])
    }

    @Test("the Now badge shows the decisions count")
    func nowBadgeShowsWaiting() async {
        let router = AppRouter(api: FixtureAPI().client)

        await router.refresh()

        // The fixture's summary says 4 are waiting, though it lists 5 items.
        #expect(router.badge(for: .now) == 4)
        #expect(AppTab.allCases.filter { $0 != .now }.allSatisfy { router.badge(for: $0) == 0 })
        #expect(router.person == AgentAvatarContent(name: "Alex Example", isPerson: true))

        // Nothing waiting is a count of zero, which the tab bar and the
        // sidebar both hide.
        let data = Data(#"{"data": {"items": [], "summary": {"waiting": 0, "held_up": 0, "agents_working": 0}}}"#.utf8)
        let empty = AppRouter(api: FixtureAPI(replacing: [Operations.ListMyDecisions.id: data]).client)
        await empty.refresh()

        #expect(empty.person != nil, "the refresh did not run")
        #expect(empty.badge(for: .now) == 0)
    }

    @Test("at launch the router asks the stub's fixtures, else the client it is given")
    func launchPicksClient() async {
        let stubbed = AppRouter.atLaunch(arguments: ["Stride", "-StrideStubSignIn", "allow"], api: nil)
        await stubbed.refresh()
        #expect(stubbed.badge(for: .now) == 4)

        let given = AppRouter.atLaunch(arguments: ["Stride"], api: FixtureAPI().client)
        await given.refresh()
        #expect(given.badge(for: .now) == 4)
        #expect(given.person != nil)

        // With no client there is nothing to ask, so the shell stays empty.
        let none = AppRouter.atLaunch(arguments: ["Stride"], api: nil)
        await none.refresh()
        #expect(none.badge(for: .now) == 0)
        #expect(none.person == nil)
    }

    @Test("coming back connects the live updates again")
    func refreshResumesLive() async {
        let asked = OSAllocatedUnfairLock(initialState: 0)
        let live = LiveChannel(
            socketToken: {
                asked.withLock { $0 += 1 }
                return .unavailable
            },
            connect: { _ in preconditionFailure("an unavailable answer never connects") },
            pause: { _ in },
            signOut: {}
        )
        let router = AppRouter(api: nil, live: live)
        let updates = await live.updates(of: .inbox)

        await Self.wait { asked.withLock { $0 } == 1 }
        await router.refresh()
        await Self.wait { asked.withLock { $0 } == 2 }
        // The channel runs only while someone listens.
        withExtendedLifetime(updates) {}

        #expect(asked.withLock { $0 } == 2)
    }

    @Test("a sign-out closes the live updates and drops their state")
    func signOutForgetsLive() async {
        let live = LiveChannel(
            socketToken: { .failed },
            connect: { _ in preconditionFailure("a failed answer never connects") },
            pause: { _ in try await Task.sleep(for: .seconds(3600)) },
            signOut: {}
        )
        let router = AppRouter(api: nil, live: live)
        let updates = await live.updates(of: .inbox)
        await Self.waitFor { await live.current == .waiting }

        router.follow(.signIn)

        await Self.waitFor { await !live.isRunning }
        withExtendedLifetime(updates) {}
        #expect(await !live.isRunning)
        #expect(await live.current == .idle)
    }

    @Test("a failed answer keeps what the shell shows")
    func failedRefreshKeepsState() async {
        let isOffline = OSAllocatedUnfairLock(initialState: false)
        let router = AppRouter(api: FixtureAPI(isOffline: { isOffline.withLock { $0 } }).client)
        await router.refresh()

        // The device goes offline and the app becomes active again.
        isOffline.withLock { $0 = true }
        await router.refresh()

        #expect(router.badge(for: .now) == 4)
        #expect(router.person == AgentAvatarContent(name: "Alex Example", isPerson: true))

        let unreachable: Set = [Operations.GetMe.id, Operations.ListMyDecisions.id]
        let offline = AppRouter(api: FixtureAPI(unreachable: unreachable).client)
        await offline.refresh()

        #expect(offline.badge(for: .now) == 0)
        #expect(offline.person == nil)
    }

    @Test("signing out from any tab clears the shell", arguments: AppTab.allCases)
    func signOutClears(tab: AppTab) async {
        let router = AppRouter(api: FixtureAPI().client)
        await router.refresh()
        router.select(tab)
        router.push(.task("W1"), on: tab)
        router.showSettings()

        router.follow(.signIn)

        #expect(router.selectedTab == .now)
        #expect(router.paths.isEmpty)
        #expect(router.sheet == nil)
        #expect(router.person == nil)
        #expect(router.badge(for: .now) == 0)
    }

    @Test("an answer that set out before a sign-out is dropped")
    func lateAnswerDropped() async {
        let router = AppRouter(api: FixtureAPI().client)

        // The refresh runs until it waits on the server, then the sign-out
        // lands before the answers do.
        let refresh = Task { await router.refresh() }
        await Task.yield()
        router.follow(.signIn)
        await refresh.value

        #expect(router.person == nil)
        #expect(router.badge(for: .now) == 0)
    }

    @Test("the shell keeps its state while it is the screen")
    func shellKeepsState() async {
        let router = AppRouter(api: FixtureAPI().client)
        await router.refresh()
        router.select(.agents)

        router.follow(.shell)

        #expect(router.selectedTab == .agents)
        #expect(router.badge(for: .now) == 4)
    }

    @Test("the corner buttons open New task and Settings")
    func cornerButtons() {
        let router = AppRouter(api: nil)

        router.showNewTask()
        #expect(router.sheet == .newTask)

        router.showSettings()
        #expect(router.sheet == .settings)
    }

    @Test("tab paths start empty and count as empty once every stack is popped")
    func tabPaths() {
        var paths = TabPaths()
        #expect(paths.isEmpty)
        #expect(AppTab.allCases.allSatisfy { paths[$0].isEmpty })

        paths[.agents] = [.task("W1")]
        #expect(paths.isEmpty == false)
        #expect(paths[.agents] == [.task("W1")])

        paths[.agents] = []
        #expect(paths.isEmpty)
    }

    @Test("every tab has its own title and symbol")
    func tabsDiffer() {
        #expect(Set(AppTab.allCases.map(\.systemImage)).count == AppTab.allCases.count)
        #expect(AppTab.allCases.map { $0.title.resolved(in: Locale(identifier: "en")) } == ["Now", "Review", "Boards", "Agents"])
        #expect(AppTab.allCases.map { $0.title.resolved(in: Locale(identifier: "de")) } == ["Jetzt", "Überprüfung", "Boards", "Agenten"])
    }

    /// Waits up to five seconds for `condition`.
    private static func wait(until condition: () -> Bool) async {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func waitFor(_ condition: () async -> Bool) async {
        for _ in 0..<500 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
