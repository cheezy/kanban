import SwiftUI

/// One thing the app does. Its first words are bold through the `**` marker in
/// the string, so each language puts them where its word order needs them.
struct SignInPoint: View {
    @Environment(\.locale) private var locale

    /// Puts the dot's middle at about the middle of a lowercase letter.
    @ScaledMetric(relativeTo: .body) private var dotLift = 4.5

    /// Names the point's text for the UI tests.
    static let identifier = "sign-in-point"

    let text: LocalizedStringResource
    let color: Color

    var body: some View {
        let lift = dotLift

        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + lift }
                .accessibilityHidden(true)

            Text(markedUp)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(Self.identifier)
        }
    }

    /// In the view's own locale, so a preview or a test in another language reads
    /// in it too.
    private var markedUp: AttributedString {
        var resource = text
        resource.locale = locale

        return AttributedString(localized: resource)
    }
}
