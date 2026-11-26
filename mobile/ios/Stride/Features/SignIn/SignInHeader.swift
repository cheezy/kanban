import SwiftUI

/// The logo, the name and what the app is for.
struct SignInHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(.strideLogoTile)
                .resizable()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)

            Text(.signInTitle)
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)

            Text(.signInTagline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
