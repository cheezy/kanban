import SwiftUI

/// Request changes, and Approve or where to approve a large change. The
/// buttons stay disabled until they send their decisions, in the next goal
/// (`ReviewModel.canDecide`). Pinned under the review side by side, or,
/// `inline`, stacked at the end of the scrolled review.
struct ReviewBottomBar: View {
    let canDecide: Bool
    let approvableHere: Bool
    var inline = false
    let requestChanges: () -> Void
    let approve: () -> Void

    var body: some View {
        let layout = inline ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        layout {
            Button(action: requestChanges) { Text(.reviewRequestChanges) }
                .buttonStyle(.stride)
                .accessibilityIdentifier("review-request-changes")
            if approvableHere {
                Button(action: approve) {
                    Label { Text(.reviewApprove) } icon: { Image(systemName: "faceid") }
                }
                .buttonStyle(.stridePrimary)
                .accessibilityIdentifier("review-approve")
            } else {
                Button {} label: {
                    Label { Text(.reviewApproveElsewhere) } icon: { Image(systemName: "lock") }
                }
                .buttonStyle(.stride)
                .disabled(true)
                .accessibilityIdentifier("review-approve-elsewhere")
            }
        }
        .disabled(!canDecide)
        .modifier(PinnedBar(isPinned: !inline))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review-bottom-bar")
    }
}
