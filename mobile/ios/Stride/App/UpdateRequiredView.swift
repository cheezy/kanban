import SwiftUI

/// Takes the place of the whole app once the server refuses this version of it.
struct UpdateRequiredView: View {
    let storeURL: URL

    var body: some View {
        GeometryReader { screen in
            ScrollView {
                UpdateRequiredMessage(storeURL: storeURL)
                    .frame(maxWidth: .infinity, minHeight: screen.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background()
    }
}

#Preview("Light") {
    UpdateRequiredView(storeURL: URL(string: "https://apps.apple.com")!)
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    UpdateRequiredView(storeURL: URL(string: "https://apps.apple.com")!)
        .preferredColorScheme(.dark)
}

#Preview("German, largest text") {
    UpdateRequiredView(storeURL: URL(string: "https://apps.apple.com")!)
        .environment(\.locale, Locale(identifier: "de"))
        .dynamicTypeSize(.accessibility5)
}
