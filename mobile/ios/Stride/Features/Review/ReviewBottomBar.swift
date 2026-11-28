import SwiftUI

/// Request changes, and Approve or where to approve a large change. Each
/// button is enabled only while it can send its decision: Approve while the
/// device is online and nothing is on its way (`ReviewModel.canApprove`), and
/// Request changes once it sends its notes. Pinned under the review side by
/// side, or, `inline`, stacked at the end of the scrolled review.
struct ReviewBottomBar: View {
    let canApprove: Bool
    let canRequestChanges: Bool
    let isApproving: Bool
    let approvableHere: Bool
    var inline = false
    let requestChanges: () -> Void
    let approve: () -> Void

    var body: some View {
        let layout = inline ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        layout {
            Button(action: requestChanges) { Text(.reviewRequestChanges) }
                .buttonStyle(.stride)
                .disabled(!canRequestChanges)
                .accessibilityIdentifier("review-request-changes")
            if approvableHere {
                Button(action: approve) {
                    Label { Text(.reviewApprove) } icon: { approveIcon }
                }
                .buttonStyle(.stridePrimary)
                .disabled(!canApprove)
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
        .modifier(PinnedBar(isPinned: !inline))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review-bottom-bar")
    }

    /// Face ID's glyph, or a spinner while the approval is on its way.
    @ViewBuilder
    private var approveIcon: some View {
        if isApproving {
            ProgressView()
        } else {
            Image(systemName: "faceid")
        }
    }
}
