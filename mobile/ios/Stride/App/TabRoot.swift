import SwiftUI

/// A tab's first screen: an optional row of corner buttons, then the tab's
/// title, large, until the screen's own task fills it in. On a phone the
/// navigation bar stays hidden here and shows on the screens pushed after it.
/// In the iPad's detail column it shows, empty, only while the sidebar is
/// hidden, because it then holds the button that brings the sidebar back.
struct TabRoot<Corner: View>: View {
    @Environment(\.showsDetailBar) private var showsDetailBar

    let tab: AppTab
    /// A screen pushed after the first keeps its bar, which holds its back
    /// button. Until each route's own screen is built, it shows this one.
    let isPushed: Bool
    @ViewBuilder let corner: Corner

    init(tab: AppTab, isPushed: Bool = false, @ViewBuilder corner: () -> Corner) {
        self.tab = tab
        self.isPushed = isPushed
        self.corner = corner()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                corner
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)

                Text(tab.title)
                    .textStyle(.largeTitle)
                    .foregroundStyle(ColorToken.ink.color)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("tab-title")
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
        }
        .background(ColorToken.bg.color)
        .toolbar(isPushed || showsDetailBar ? .automatic : .hidden, for: .navigationBar)
    }
}

extension TabRoot where Corner == EmptyView {
    init(tab: AppTab, isPushed: Bool = false) {
        self.init(tab: tab, isPushed: isPushed) { EmptyView() }
    }
}

#if DEBUG
#Preview("Light") {
    NavigationStack {
        TabRoot(tab: .now) { ShellCornerButtons(router: AppRouter(api: nil)) }
    }
    .preferredColorScheme(.light)
}

#Preview("Dark") {
    NavigationStack { TabRoot(tab: .agents) }
        .preferredColorScheme(.dark)
}
#endif
