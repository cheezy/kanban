import StrideKit
import SwiftUI

/// The signed-in app: a tab bar in a compact width, and a sidebar in a regular
/// one, so an iPad in a narrow split view gets the phone's tab bar. New task
/// and the avatar sit in the top corner of Now on a phone, and above the
/// sidebar's tabs on an iPad, where every tab can reach them.
struct AppShell: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var columns = NavigationSplitViewVisibility.all

    @Bindable var router: AppRouter

    var body: some View {
        Group {
            if sizeClass == .compact {
                tabs
            } else {
                sidebar
            }
        }
        .tint(ColorToken.strideOrangeInk.color)
        .sheet(item: $router.sheet, content: ShellSheetView.init)
        .task(id: scenePhase) {
            if scenePhase == .active { await router.refresh() }
        }
        .task { await router.now.observe() }
    }

    private var tabs: some View {
        TabView(selection: selection) {
            ForEach(AppTab.allCases) { tab in
                stack(for: tab, showsCornerButtons: tab == .now)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .badge(router.badge(for: tab))
                    .tag(tab)
            }
        }
    }

    private var sidebar: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(AppTab.allCases, rowContent: sidebarRow)
            .safeAreaInset(edge: .top) {
                ShellCornerButtons(router: router)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 16)
            }
            .navigationTitle(Text(.signInTitle))
        } detail: {
            // Once the sidebar is hidden, the button that brings it back is in
            // the detail column's bar, which shows only then.
            stack(for: router.selectedTab, showsCornerButtons: false)
                .id(router.selectedTab)
                .environment(\.showsDetailBar, columns == .detailOnly)
        }
    }

    /// A sidebar row is a button that draws its own selection, as the design
    /// does: stride-orange-ink on stride-orange-soft, which reaches 4.5:1 in
    /// both themes. The list's own selection fills the row with the tint and
    /// draws white text on it when the sidebar has focus, which fails in dark,
    /// where the tint is light. The count is a pill of ink on surface, and
    /// VoiceOver reads it as the tab's value, as it reads a badge, rather than
    /// as an element after it.
    private func sidebarRow(_ tab: AppTab) -> some View {
        let count = router.badge(for: tab)
        let isSelected = tab == router.selectedTab
        return Button {
            router.select(tab)
        } label: {
            HStack {
                Label(tab.title, systemImage: tab.systemImage)
                    .accessibilityIdentifier("sidebar-tab-title")
                Spacer()
                if count > 0 {
                    Text(count, format: .number)
                        .textStyle(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(ColorToken.ink.color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(ColorToken.surface.color, in: Capsule())
                        .accessibilityHidden(true)
                        .accessibilityIdentifier("sidebar-count")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle((isSelected ? ColorToken.strideOrangeInk : ColorToken.ink).color)
        .listRowBackground(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.lg)
                .fill(isSelected ? ColorToken.strideOrangeSoft.color : .clear)
                .padding(.horizontal, 10)
        )
        .accessibilityValue(count > 0 ? Text(count, format: .number) : Text(verbatim: ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("sidebar-tab")
    }

    private func stack(for tab: AppTab, showsCornerButtons: Bool) -> some View {
        NavigationStack(path: $router.paths[tab]) {
            root(for: tab, showsCornerButtons: showsCornerButtons)
            // The screens each route opens are still to be built.
            .navigationDestination(for: AppRoute.self) { _ in
                TabRoot(tab: tab, isPushed: true)
            }
        }
    }

    @ViewBuilder
    private func root(for tab: AppTab, showsCornerButtons: Bool) -> some View {
        switch tab {
        case .now:
            NowView(model: router.now, router: router, showsCornerButtons: showsCornerButtons)
        default:
            TabRoot(tab: tab) {
                if showsCornerButtons { ShellCornerButtons(router: router) }
            }
        }
    }

    /// The tab bar sets the selection again when the selected tab is tapped,
    /// which the router reads as going back to the tab's first screen.
    private var selection: Binding<AppTab> {
        Binding(get: { router.selectedTab }, set: { router.select($0) })
    }
}

#if DEBUG
#Preview("Light") {
    AppShell(router: AppRouter(api: FixtureAPI().client))
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    AppShell(router: AppRouter(api: FixtureAPI().client))
        .preferredColorScheme(.dark)
}
#endif
