/// Each tab's stack of pushed screens. A tab nothing was pushed on has an
/// empty stack.
struct TabPaths: Equatable, Sendable {
    private var stacks: [AppTab: [AppRoute]] = [:]

    subscript(tab: AppTab) -> [AppRoute] {
        get { stacks[tab] ?? [] }
        set { stacks[tab] = newValue }
    }

    /// True when every tab is on its first screen.
    var isEmpty: Bool { stacks.values.allSatisfy(\.isEmpty) }
}
