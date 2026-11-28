import SwiftUI

/// What the file screen shows for its state: the loading, nothing-saved and
/// gone placeholders, or the file's header, its notes on the whole file, its
/// diff and the footer. A sideways swipe on the diff pages between files.
struct DiffScreenContent: View {
    let state: DiffScreenState
    let content: DiffContent?
    let position: LocalizedStringResource?
    let next: () -> Void
    let previous: () -> Void

    var body: some View {
        switch state {
        case .loading:
            LoadingSkeleton(label: .diffLoading, cardHeight: 96, identifier: "diff-loading")
        case .nothingSaved:
            NothingSavedView(message: .nowOfflineNothing, identifier: "diff-nothing-saved")
        case .gone:
            EmptyStateView(message: .diffFileGone, identifier: "diff-gone")
        case .file:
            if let content {
                DiffHeader(content: content, position: position)
                DiffFileNotes(notes: content.fileNotes)
                // On the diff alone, so the header is not under a gesture.
                DiffCodeBlock(content: content)
                    .diffPagingSwipe(next: next, previous: previous)
                Text(.diffFooter)
                    .textStyle(.footnote)
                    .foregroundStyle(ColorToken.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityRespondsToUserInteraction(false)
                    .accessibilityIdentifier("diff-footer")
            }
        }
    }
}
