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
            ReviewBottomBar(model: model, content: content, inline: inline)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            NowSkeleton(label: .reviewLoading, cardHeight: 96, identifier: "review-loading")
        case .nothingSaved:
            NowNothingSaved(identifier: "review-nothing-saved")
        case .unavailable:
            NowEmptyState(message: .reviewUnavailable, identifier: "review-unavailable")
        case .review:
            if let content = model.content {
                ReviewSections(content: content, conflict: model.conflict) {
                    Task { await model.reload() }
                }
            }
        }
    }
}

/// The review's sections, in order.
struct ReviewSections: View {
    let content: ReviewContent
    let conflict: ReviewConflictState?
    let reload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ReviewHeader(content: content)
            if let conflict {
                ReviewConflictNotice(conflict: conflict, reload: reload)
            }
            if content.tooLargeHere {
                ReviewLargeNotice()
            }
            ForEach(content.sections, id: \.self) { section in
                switch section {
                case .summary:
                    ReviewSection(title: .reviewSummary, identifier: "review-summary") {
                        Text(verbatim: content.summary ?? "")
                            .textStyle(.body)
                            .foregroundStyle(ColorToken.ink2.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .verdicts: ReviewVerdictsSection(content: content)
                case .checks: ReviewChecksSection(content: content)
                case .files: ReviewFilesSection(content: content)
                }
            }
        }
    }
}

/// The identifier, priority, what it holds up, the title, and the agent,
/// time and goal.
struct ReviewHeader: View {
    @Environment(\.locale) private var locale

    let content: ReviewContent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 8) {
                Text(verbatim: content.identifier)
                    .textStyle(.code)
                    .foregroundStyle(ColorToken.ink3.color)
                    .accessibilityIdentifier("card-identifier")
                if let priority = content.priority {
                    PriorityDot(priority: priority)
                }
                StatusPill(.decisionKindReview, tone: .review)
                if let holdsUp = content.holdsUpLabel(in: locale) {
                    StatusPill(holdsUp, tone: .blocked)
                }
            }

            Text(verbatim: content.title)
                .textStyle(.title)
                .foregroundStyle(ColorToken.ink.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("review-title")

            if let details = content.details(in: locale) {
                HStack(alignment: .top, spacing: 8) {
                    if let agent = content.agent {
                        AgentAvatar(agent, size: .small)
                            .accessibilityHidden(true)
                    }
                    Text(verbatim: details)
                        .textStyle(.footnote)
                        .foregroundStyle(ColorToken.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                // The UI tests find the agent and details line by this.
                .accessibilityIdentifier("review-details")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A titled section on a card.
struct ReviewSection<Accessory: View, Body: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize

    let title: LocalizedStringResource
    let identifier: String
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Body

    init(
        title: LocalizedStringResource,
        identifier: String,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() },
        @ViewBuilder content: () -> Body
    ) {
        self.title = title
        self.identifier = identifier
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Chosen by text size, not ViewThatFits, which swaps the heading
            // for a copy as the text grows and fails the Dynamic Type audit.
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
            layout {
                heading
                    .frame(maxWidth: typeSize.isAccessibilitySize ? nil : .infinity, alignment: .leading)
                accessory
            }
            content
        }
        .cardChrome()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private var heading: some View {
        Text(title)
            .textStyle(.label)
            .foregroundStyle(ColorToken.ink3.color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The notice above the verdicts on a change this device may not approve.
struct ReviewLargeNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(.reviewQueueTooLargePhone)
                .textStyle(.callout)
                .fontWeight(.semibold)
            Text(.reviewLargeHint)
                .textStyle(.footnote)
        }
        .foregroundStyle(ColorToken.stDoing.color)
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ColorToken.stDoingSoft.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("review-large")
    }
}

/// A review that changed since it loaded: who decided it, or a reload for
/// the new version.
struct ReviewConflictNotice: View {
    @Environment(\.locale) private var locale

    let conflict: ReviewConflictState
    let reload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .textStyle(.callout)
                .fontWeight(.semibold)
                .foregroundStyle(ColorToken.ink.color)
            Text(message)
                .textStyle(.footnote)
                .foregroundStyle(ColorToken.ink2.color)
                .accessibilityIdentifier("review-conflict-message")
            if case .alreadyDecided(_, _, at: let date?) = conflict {
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    Text(verbatim: ReviewConflictCopy.when(date, relativeTo: timeline.date, in: locale))
                        .textStyle(.footnote)
                        .foregroundStyle(ColorToken.ink2.color)
                        .accessibilityIdentifier("review-conflict-when")
                }
            }
            if conflict == .resubmitted {
                Button(action: reload) { Text(.reviewReload) }
                    .buttonStyle(.stride)
                    .accessibilityIdentifier("review-reload")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ColorToken.stReviewSoft.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review-conflict")
    }

    private var title: LocalizedStringResource {
        conflict == .resubmitted ? .reviewResubmitted : .reviewAlreadyDecided
    }

    private var message: LocalizedStringResource {
        ReviewConflictCopy.message(for: conflict)
    }
}

/// Request changes, and Approve or where to approve a large change. The
/// buttons send their decisions in the next goal. Pinned under the review
/// side by side, or, `inline`, stacked at the end of the scrolled review.
struct ReviewBottomBar: View {
    let model: ReviewModel
    let content: ReviewContent
    var inline = false

    var body: some View {
        let layout = inline ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        layout {
            Button {} label: { Text(.reviewRequestChanges) }
                .buttonStyle(.stride)
                .accessibilityIdentifier("review-request-changes")
            if content.approvableHere {
                Button {} label: {
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
        .disabled(!model.canAct)
        .modifier(PinnedBar(isPinned: !inline))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review-bottom-bar")
    }
}

/// The pinned bar's chrome: a readable column on a surface with a line
/// above it. Inline buttons take the scrolled review's own padding.
private struct PinnedBar: ViewModifier {
    let isPinned: Bool

    func body(content: Content) -> some View {
        if isPinned {
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .background(ColorToken.surface.color)
                .overlay(alignment: .top) { Divider().overlay(ColorToken.line.color) }
        } else {
            content
                .padding(.top, 8)
        }
    }
}

/// The screen a file row opens until the diff screen (design section 6.5)
/// is built: the file's path.
struct ReviewFilePlaceholder: View {
    let path: String

    var body: some View {
        ScrollView {
            Text(verbatim: path)
                .textStyle(.code)
                .foregroundStyle(ColorToken.ink.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .accessibilityIdentifier("review-file-path")
        }
        .background(ColorToken.bg.color)
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
