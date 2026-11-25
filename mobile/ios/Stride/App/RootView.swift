import SwiftUI

/// The placeholder root. It shows only the system background, so it has no text
/// to translate; the string catalog and the generated colours come later.
struct RootView: View {
    var body: some View {
        Rectangle()
            .fill(.background)
            .ignoresSafeArea()
    }
}

#Preview("Light") {
    RootView()
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    RootView()
        .preferredColorScheme(.dark)
}
