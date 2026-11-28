import SwiftUI

/// A titled section on a card.
struct ReviewSection<Accessory: View, Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize

    let title: LocalizedStringResource
    let identifier: String
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    init(
        title: LocalizedStringResource,
        identifier: String,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() },
        @ViewBuilder content: () -> Content
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
            // The UI tests' iOS 26 audit filter finds a heading by this.
            .accessibilityIdentifier("review-section-heading")
    }
}
