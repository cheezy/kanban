import StrideKit
import SwiftUI

/// Takes the place of the Sign in button when the person is signed in but their
/// plan does not include the app. The app asks again each time it comes back.
struct LockedPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(.signInLockedTitle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)

            Text(.signInLockedMessage)
                .fixedSize(horizontal: false, vertical: true)

            Link(destination: StrideWeb.pricing) {
                Text(.signInLockedAction)
                    .font(.headline)
                    .foregroundStyle(.background)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .controlSize(.large)
            .tint(.primary)
            .accessibilityAddTraits(.isLink)
            .accessibilityRemoveTraits(.isButton)
            .padding(.top, 4)
        }
        .padding(16)
        .background(.fill.tertiary, in: .rect(cornerRadius: 16))
    }
}
