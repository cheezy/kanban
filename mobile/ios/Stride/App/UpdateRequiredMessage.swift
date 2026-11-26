import SwiftUI

/// What the Update required screen says, and its link to the App Store.
///
/// At the accessibility text sizes a line holds only a word or two, so the text
/// may be wider there and the link takes the whole width.
struct UpdateRequiredMessage: View {
    @Environment(\.dynamicTypeSize) private var textSize

    let storeURL: URL

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.app")
                .font(.largeTitle)
                .accessibilityHidden(true)

            Text(.updateRequiredTitle)
                .font(.title2)
                .bold()
                .accessibilityAddTraits(.isHeader)

            Text(.updateRequiredMessage)

            Link(destination: storeURL) {
                Text(.updateRequiredAction)
                    .bold()
                    .foregroundStyle(.background)
                    .frame(maxWidth: isLargeText ? .infinity : nil)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 16))
            .controlSize(.large)
            .tint(.primary)
            .accessibilityAddTraits(.isLink)
            .accessibilityRemoveTraits(.isButton)
            .padding(.top, 8)
        }
        .multilineTextAlignment(.center)
        .padding()
        .frame(maxWidth: isLargeText ? 640 : 400)
    }

    private var isLargeText: Bool { textSize.isAccessibilitySize }
}
