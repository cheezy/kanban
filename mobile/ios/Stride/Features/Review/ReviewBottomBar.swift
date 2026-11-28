import SwiftUI

/// Request changes, and Approve or, on a change this device may not approve,
/// Approve on tablet or web, which opens the web's Review page with the task
/// selected. Approve is enabled only while it can send its decision: while the
/// device is online and nothing is on its way (`ReviewModel.canApprove`), and
/// Request changes likewise (`ReviewModel.canRequestChanges`), which opens
/// its sheet. Pinned under the review side by
/// side, or, `inline`, stacked at the end of the scrolled review.
struct ReviewBottomBar: View {
    let canApprove: Bool
    let canRequestChanges: Bool
    let isApproving: Bool
    let approvableHere: Bool
    let canOpenOnWeb: Bool
    var inline = false
    let requestChanges: () -> Void
    let approve: () -> Void
    let openOnWeb: () -> Void

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
                Button(action: openOnWeb) {
                    Label { Text(.reviewApproveElsewhere) } icon: { Image(systemName: "arrow.up.right.square") }
                }
                .buttonStyle(.stride)
                .disabled(!canOpenOnWeb)
                .accessibilityHint(Text(.reviewApproveElsewhereHint))
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
