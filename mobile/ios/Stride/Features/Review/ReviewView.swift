import StrideKit
import SwiftUI

/// One pending review, verdicts first, in the order of design section 6.4:
/// the header, what the agent says it did, the verdict tiles, tests and
/// checks, the security review, exploratory testing, the files (flagged
/// first) and the bottom bar. The server's text is shown as plain text.
struct ReviewView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var model: ReviewModel

    init(model: ReviewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let banner = model.offlineBanner {
                    OfflineBanner(content: banner)
                        .accessibilityIdentifier("review-offline")
                }
                content
                // At the accessibility text sizes a pinned bar would cover
                // half the screen and split its words, so the buttons follow
                // the files instead.
                if typeSize.isAccessibilitySize {
                    bottomBar(inline: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            // A readable column on an iPad's full width.
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(ColorToken.bg.color)
        .navigationTitle(Text(.tabReview))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if !typeSize.isAccessibilitySize {
                bottomBar(inline: false)
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .task { await model.observe() }
    }

    @ViewBuilder
    private func bottomBar(inline: Bool) -> some View {
        if model.state == .review, let content = model.content {
            // The decisions are sent in the next goal; until then the bar
            // stays disabled (`ReviewModel.canDecide`).
            ReviewBottomBar(
                canDecide: model.canDecide,
                approvableHere: content.approvableHere,
                inline: inline,
                requestChanges: {},
                approve: {}
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            LoadingSkeleton(label: .reviewLoading, cardHeight: 96, identifier: "review-loading")
        case .nothingSaved:
            NothingSavedView(message: .nowOfflineNothing, identifier: "review-nothing-saved")
        case .unavailable:
            EmptyStateView(message: .reviewUnavailable, identifier: "review-unavailable")
        case .review:
            if let content = model.content {
                ReviewSections(content: content, conflict: model.conflict) {
                    Task { await model.reload() }
                }
            }
        }
    }
}

#if DEBUG
private struct ReviewPreview: View {
    let replacements: [String: Data]

    init(replacing replacements: [String: Data] = [:]) {
        self.replacements = replacements
    }

    var body: some View {
        NavigationStack {
            ReviewView(model: ReviewModel(taskID: 4812, api: FixtureAPI(replacing: replacements).client))
        }
    }
}

#Preview("Light") {
    ReviewPreview().preferredColorScheme(.light)
}

#Preview("Dark") {
    ReviewPreview().preferredColorScheme(.dark)
}

#Preview("German, largest text") {
    ReviewPreview()
        .environment(\.locale, Locale(identifier: "de"))
        .dynamicTypeSize(.accessibility5)
}
#endif
