import StrideKit
import SwiftUI

/// The Review tab's first screen: the reviews waiting on the person, in the
/// server's order, each with what it holds up, its verdicts and its size.
/// A row opens its review.
struct ReviewQueueView: View {
    @Environment(\.showsDetailBar) private var showsDetailBar

    let model: ReviewQueueModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ReviewQueueHeader(waiting: model.state == .rows ? model.rows.count : nil)
                    .padding(.top, 8)

                if let banner = model.offlineBanner {
                    OfflineBanner(content: banner)
                        .accessibilityIdentifier("review-offline")
                }

                content
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            // A readable column on an iPad's full width.
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(ColorToken.bg.color)
        .refreshable { await model.load() }
        .toolbar(showsDetailBar ? .automatic : .hidden, for: .navigationBar)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            NowSkeleton(label: .reviewQueueLoading, cardHeight: 112, identifier: "review-loading")
        case .nothingSaved:
            NowNothingSaved(identifier: "review-nothing-saved")
        case .empty:
            NowEmptyState(message: .reviewQueueEmpty, identifier: "review-empty")
        case .rows:
            LazyVStack(spacing: 12) {
                ForEach(model.rows) { row in
                    if let taskID = row.taskID {
                        NavigationLink(value: AppRoute.review(taskID)) {
                            ReviewQueueRowView(row: row)
                        }
                        .buttonStyle(.plain)
                        // A link takes its row's parts into one button, which
                        // the UI tests find by this identifier.
                        .accessibilityIdentifier("review-open")
                    } else {
                        ReviewQueueRowView(row: row)
                    }
                }
            }
            // The UI tests find the queue by this identifier.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("review-rows")
        }
    }
}

/// The tab's title, and how many reviews wait once the queue has loaded.
struct ReviewQueueHeader: View {
    let waiting: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(.tabReview)
                .textStyle(.largeTitle)
                .foregroundStyle(ColorToken.ink.color)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("tab-title")
            if let waiting {
                Text(.reviewQueueWaiting(count: waiting))
                    .textStyle(.subheadline)
                    .foregroundStyle(ColorToken.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("review-waiting")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One pending review: its identifier, priority and age, its title, what it
/// holds up, its size, its agent, the first failed note and its verdicts.
/// The server's text is shown as plain text.
struct ReviewQueueRowView: View {
    @Environment(\.locale) private var locale

    let row: ReviewQueueRow

    private var content: DecisionCardContent { row.content }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: content.identifier)
                    .textStyle(.code)
                    .foregroundStyle(ColorToken.ink3.color)
                    .accessibilityIdentifier("card-identifier")
                if let priority = content.priority {
                    PriorityDot(priority: priority)
                }
                Spacer(minLength: 8)
                if content.since != nil {
                    age
                }
            }

            Text(verbatim: content.title)
                .textStyle(.callout)
                .foregroundStyle(ColorToken.ink.color)
                .fixedSize(horizontal: false, vertical: true)

            if content.holdsUp > 0 || row.sizeLabel != nil || row.files != nil {
                FlowLayout(spacing: 8) {
                    if content.holdsUp > 0 {
                        StatusPill(.decisionHoldsUp(count: content.holdsUp), tone: .blocked)
                    }
                    if let label = row.sizeLabel {
                        StatusPill(label.text, tone: .doing)
                            .accessibilityIdentifier("review-size-label")
                    }
                    if let files = row.files {
                        Text(.reviewQueueFiles(count: files))
                            .textStyle(.footnote)
                            .foregroundStyle(ColorToken.ink2.color)
                    }
                }
            }

            if let agent = content.agent {
                HStack(alignment: .top, spacing: 8) {
                    AgentAvatar(agent, size: .small)
                        .accessibilityHidden(true)
                    Text(verbatim: agent.name)
                        .textStyle(.footnote)
                        .foregroundStyle(ColorToken.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }

            if let issue = content.issue {
                Text(verbatim: issue)
                    .textStyle(.footnote)
                    .foregroundStyle(ColorToken.stBlocked.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !content.verdicts.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(content.verdicts, id: \.self) { VerdictPill(verdict: $0) }
                }
            }
        }
        .cardChrome()
        // Each part reads on its own, as on a Now card; the UI tests find the
        // row by this identifier.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review-row")
    }

    /// The age, redrawn each minute.
    private var age: some View {
        TimelineView(.everyMinute) { context in
            Text(verbatim: content.age(at: context.date, in: locale) ?? "")
                .textStyle(.code)
                .foregroundStyle(ColorToken.ink3.color)
                .accessibilityLabel(Text(verbatim: content.age(at: context.date, in: locale, width: .wide) ?? ""))
                .accessibilityIdentifier("card-age")
        }
    }
}

#if DEBUG
private struct ReviewQueuePreview: View {
    @State private var model: ReviewQueueModel

    init(replacing replacements: [String: Data] = [:]) {
        _model = State(initialValue: ReviewQueueModel(api: FixtureAPI(replacing: replacements).client))
    }

    var body: some View {
        NavigationStack {
            ReviewQueueView(model: model)
        }
        .task { await model.load() }
    }
}

#Preview("Light") {
    ReviewQueuePreview().preferredColorScheme(.light)
}

#Preview("Dark") {
    ReviewQueuePreview().preferredColorScheme(.dark)
}

#Preview("German, largest text") {
    ReviewQueuePreview()
        .environment(\.locale, Locale(identifier: "de"))
        .dynamicTypeSize(.accessibility5)
}

#Preview("Empty") {
    ReviewQueuePreview(replacing: [Operations.ListMyReviews.id: Data(#"{"data": []}"#.utf8)])
}
#endif
