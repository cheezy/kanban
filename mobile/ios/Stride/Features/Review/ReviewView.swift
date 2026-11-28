import AuthenticationServices
import StrideKit
import SwiftUI

/// One pending review, verdicts first, in the order of design section 6.4:
/// the header, what the agent says it did, the verdict tiles, tests and
/// checks, the security review, exploratory testing, the files (flagged
/// first) and the bottom bar. The server's text is shown as plain text.
struct ReviewView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL
    @Environment(\.webAuthenticationSession) private var webSession
    @State private var model: ReviewModel

    /// Opens the next review in the queue, after a decision.
    private let next: () -> Void

    init(model: ReviewModel, next: @escaping () -> Void = {}) {
        _model = State(initialValue: model)
        self.next = next
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
                    decisions(inline: true)
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
                decisions(inline: false)
            }
        }
        .sheet(item: $model.changesSheet) { sheet in
            RequestChangesSheet(model: sheet)
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .task { await model.observe() }
    }

    /// What a decision came to, above the buttons, and the buttons.
    @ViewBuilder
    private func decisions(inline: Bool) -> some View {
        if model.state == .review, model.content != nil {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    if let problem = model.approveProblem {
                        NoticeView(text: problem.text, isProblem: true, identifier: "review-approve-problem") {
                            model.dismissApproveProblem()
                        }
                        // The whole notice, Close included, for the audit;
                        // the toast names itself, and a container around it
                        // alone would take its identifier.
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("review-problem-notice")
                    }
                    if let message = model.approvedMessage(in: locale) {
                        DecisionToast(message: message, kind: .approved, next: next)
                    }
                    if let message = model.changesRequestedMessage {
                        DecisionToast(message: message, kind: .changesRequested, next: next)
                    }
                }
                // Over the pinned bar, in its readable column.
                .padding(.horizontal, inline ? 0 : 12)
                .padding(.bottom, model.showsDecisionNotice ? 8 : 0)
                .frame(maxWidth: inline ? .infinity : 640)
                ReviewBottomBar(
                    canApprove: model.canApprove,
                    canRequestChanges: model.canRequestChanges,
                    isApproving: model.isApproving,
                    approvableHere: model.approvableHere,
                    canOpenOnWeb: model.canOpenOnWeb,
                    inline: inline,
                    requestChanges: model.openRequestChanges,
                    approve: approve,
                    openOnWeb: openOnWeb
                )
            }
        }
    }

    /// The web's Review page with this task selected, in the browser.
    private func openOnWeb() {
        if let url = model.webReviewURL { openURL(url) }
    }

    private func approve() {
        let web = SystemWebAuthenticator(session: webSession)
        Task { await model.approve(web: web) }
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
                ReviewSections(content: content, conflict: model.conflict, largeChange: model.largeChange) {
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
