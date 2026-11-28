import SwiftUI

/// Back to verdicts and Next file. Pinned under the diff side by side, or,
/// `inline`, stacked at the end of the scrolled diff.
struct DiffBottomBar: View {
    let canPage: Bool
    var inline = false
    let back: () -> Void
    let next: () -> Void

    var body: some View {
        let layout = inline ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        layout {
            Button(action: back) { Text(.diffBackToVerdicts) }
                .buttonStyle(.stride)
                .accessibilityIdentifier("diff-back")
            Button(action: next) {
                HStack(spacing: 6) {
                    Text(.diffNextFile)
                    Image(systemName: "chevron.right")
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.stridePrimary)
            .disabled(!canPage)
            .accessibilityIdentifier("diff-next")
        }
        .modifier(PinnedBar(isPinned: !inline))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("diff-bottom-bar")
    }
}
