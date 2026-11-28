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
            LoadingSkeleton(label: .reviewQueueLoading, cardHeight: 112, identifier: "review-loading")
        case .nothingSaved:
            NothingSavedView(message: .nowOfflineNothing, identifier: "review-nothing-saved")
        case .empty:
            EmptyStateView(message: .reviewQueueEmpty, identifier: "review-empty")
        case .rows:
            LazyVStack(spacing: 12) {
                ForEach(model.rows) { row in
                    // One container per row, so the lazy stack sees one view
                    // whether or not the row opens.
                    VStack(spacing: 0) {
                        if let taskID = row.taskID {
                            NavigationLink(value: AppRoute.review(taskID)) {
                                ReviewQueueRowView(row: row)
                            }
                            .buttonStyle(.plain)
                            // One button that reads its row's parts in turn. iOS
                            // 27 combines them by itself, but iOS 18 left the
                            // link with no label at all (W2797). The UI tests
                            // find the button by this identifier.
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("review-open")
                        } else {
                            ReviewQueueRowView(row: row)
                        }
                    }
                }
            }
            // The UI tests find the queue by this identifier.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("review-rows")
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
