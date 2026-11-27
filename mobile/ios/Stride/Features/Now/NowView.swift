import StrideKit
import SwiftUI

/// The Now tab's first screen: what waits on the person, newest problem
/// first in the server's order, with a filter for each kind of decision.
struct NowView: View {
    @Environment(\.showsDetailBar) private var showsDetailBar
    @Environment(\.openURL) private var openURL

    @Bindable var model: NowModel
    let router: AppRouter
    let showsCornerButtons: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if showsCornerButtons {
                    ShellCornerButtons(router: router)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
                }

                NowHeader(summary: model.summary)
                    .padding(.top, showsCornerButtons ? 0 : 8)

                if let banner = model.offlineBanner {
                    OfflineBanner(content: banner)
                        .accessibilityIdentifier("now-offline")
                }

                NowFilterBar(selection: $model.filter, count: model.count(for:))

                Text(.nowSorted)
                    .textStyle(.label)
                    .foregroundStyle(ColorToken.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)

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
            NowSkeleton()
        case .nothingSaved:
            NowNothingSaved()
        case .empty:
            NowEmptyState()
        case .cards:
            LazyVStack(spacing: 12) {
                ForEach(model.visibleCards) { card in
                    NowCardView(card: card, isOffline: model.isOffline) { action in
                        perform(action, on: card)
                    }
                }
            }
            // The UI tests find the list by this identifier.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("now-cards")
        }
    }

    private func perform(_ action: NowAction, on card: NowCard) {
        guard let destination = card.destination(for: action) else { return }

        if let url = router.open(destination) { openURL(url) }
    }
}

#if DEBUG
private struct NowPreview: View {
    @State private var router = AppRouter(api: FixtureAPI().client)

    var body: some View {
        NavigationStack {
            NowView(model: router.now, router: router, showsCornerButtons: true)
        }
        .task { await router.now.load() }
    }
}

#Preview("Light") {
    NowPreview().preferredColorScheme(.light)
}

#Preview("Dark") {
    NowPreview().preferredColorScheme(.dark)
}

#Preview("German, largest text") {
    NowPreview()
        .environment(\.locale, Locale(identifier: "de"))
        .dynamicTypeSize(.accessibility5)
}
#endif
