import StrideKit
import SwiftUI

/// The Update required screen once the server refuses this version of the app.
/// Otherwise the Sign in screen until the device is signed in and the person's
/// plan includes the app, and then a placeholder that shows only the system
/// background.
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase

    let update: AppUpdateState
    let signIn: SignInModel

    var body: some View {
        content
            .task { await signIn.observeSignIn() }
            .task(id: scenePhase) {
                if scenePhase == .active { await signIn.recheckAccess() }
            }
    }

    @ViewBuilder private var content: some View {
        if let storeURL = update.storeURL {
            UpdateRequiredView(storeURL: storeURL)
        } else {
            switch signIn.phase {
            case .signedOut, .signingIn, .locked:
                SignInView(model: signIn)
            case .starting, .signedIn:
                Rectangle()
                    .fill(.background)
                    .ignoresSafeArea()
            }
        }
    }
}

#if DEBUG
#Preview("Signed in, light") {
    RootView(update: AppUpdateState(), signIn: SignInModel(services: nil, phase: .signedIn(.unlocked)))
        .preferredColorScheme(.light)
}

#Preview("Signed in, dark") {
    RootView(update: AppUpdateState(), signIn: SignInModel(services: nil, phase: .signedIn(.unlocked)))
        .preferredColorScheme(.dark)
}

#Preview("Signed out") {
    RootView(update: AppUpdateState(), signIn: StubSignIn.allow.model())
}
#endif
