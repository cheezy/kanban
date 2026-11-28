import StrideKit
import SwiftUI

/// One file of a pending review: its header, the server-highlighted diff
/// with each reviewer note under its line, and Back to verdicts and Next
/// file. A horizontal swipe on the diff pages between the files too, and VoiceOver has
/// Next file and Previous file as actions, so nothing rests on the swipe.
/// The server's text is shown as plain text, never run or linked.
struct DiffView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.dismiss) private var dismiss
    @State private var model: DiffModel

    init(model: DiffModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let banner = model.offlineBanner {
                    OfflineBanner(content: banner)
                        .accessibilityIdentifier("diff-offline")
                }
                DiffScreenContent(
                    state: model.state,
                    content: model.content,
                    position: model.position,
                    next: { page(.next) },
                    previous: { page(.previous) }
                )
                // At the accessibility text sizes the buttons follow the
                // diff rather than covering half the screen.
                if typeSize.isAccessibilitySize, model.state != .loading {
                    DiffBottomBar(canPage: model.canPage, inline: true, back: { dismiss() }, next: { page(.next) })
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(ColorToken.bg.color)
        .navigationTitle(Text(verbatim: model.content?.name ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if !typeSize.isAccessibilitySize, model.state != .loading {
                DiffBottomBar(canPage: model.canPage, back: { dismiss() }, next: { page(.next) })
            }
        }
        // Only while there is another file to go to.
        .accessibilityActions {
            if model.canPage {
                Button { page(.next) } label: { Text(.diffNextFile) }
                Button { page(.previous) } label: { Text(.diffPreviousFile) }
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .task { await model.observe() }
    }

    private enum Direction { case next, previous }

    private func page(_ direction: Direction) {
        Task {
            switch direction {
            case .next: await model.showNext()
            case .previous: await model.showPrevious()
            }
        }
    }
}

#if DEBUG
private struct DiffPreview: View {
    var body: some View {
        NavigationStack {
            DiffView(model: DiffModel(target: DiffPreview.target, api: FixtureAPI().client))
        }
    }

    static let target = ReviewFileTarget(
        taskID: 4812,
        index: 2,
        filesVersion: "v1-2026-11-18T09:30:00Z",
        files: [
            ReviewFileRow(index: 2, path: "lib/example/greeting.ex", additions: 3, deletions: 1, isFlagged: true),
            ReviewFileRow(index: 0, path: "mobile/ios/Stride/SignInView.swift", additions: 12, deletions: 4, isFlagged: false),
        ]
    )
}

#Preview("Light") {
    DiffPreview().preferredColorScheme(.light)
}

#Preview("Dark") {
    DiffPreview().preferredColorScheme(.dark)
}

#Preview("German, largest text") {
    DiffPreview()
        .environment(\.locale, Locale(identifier: "de"))
        .dynamicTypeSize(.accessibility5)
}
#endif
