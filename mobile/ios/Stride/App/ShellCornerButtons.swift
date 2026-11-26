import SwiftUI

/// New task and the person's avatar, which opens Settings: the row above a
/// tab's title on a phone, and above the sidebar's tabs on an iPad. They sit
/// in the screen rather than the navigation bar, so they grow with the text.
struct ShellCornerButtons: View {
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 36

    let router: AppRouter

    var body: some View {
        HStack(spacing: 10) {
            Button(action: router.showNewTask) {
                Image(systemName: "plus")
                    .fontWeight(.semibold)
                    .foregroundStyle(ColorToken.ink.color)
                    .frame(width: side, height: side)
                    .background(ColorToken.surfaceSunken.color, in: Circle())
                    .touchTarget()
            }
            .accessibilityLabel(Text(.shellNewTask))

            Button(action: router.showSettings) {
                AgentAvatar(router.person ?? AgentAvatarContent(name: "", isPerson: true))
                    .touchTarget()
            }
            .accessibilityLabel(Text(.shellSettings))
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    /// Each button's own label takes at least 44 points, so the 36-point
    /// circle and avatar are each a 44-point target.
    func touchTarget() -> some View {
        frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
    }
}
