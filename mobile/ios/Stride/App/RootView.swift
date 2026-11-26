import StrideKit
import SwiftUI

/// The Update required screen once the server refuses this version of the app,
/// and otherwise a placeholder that shows only the system background.
struct RootView: View {
    let update: AppUpdateState

    var body: some View {
        if let storeURL = update.storeURL {
            UpdateRequiredView(storeURL: storeURL)
        } else {
            Rectangle()
                .fill(.background)
                .ignoresSafeArea()
        }
    }
}

#Preview("Light") {
    RootView(update: AppUpdateState())
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    RootView(update: AppUpdateState())
        .preferredColorScheme(.dark)
}
