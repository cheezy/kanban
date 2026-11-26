import StrideKit
import SwiftUI

/// The screen `RootScreen` picks: Update required once the server refuses this
/// version of the app, the Sign in screen until the device is signed in and
/// the person's plan includes the app, and then the shell.
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase

    let update: AppUpdateState
    let signIn: SignInModel
    let router: AppRouter

    var body: some View {
        let screen = RootScreen(storeURL: update.storeURL, phase: signIn.phase)

        content(for: screen)
            .onChange(of: screen) { router.follow(screen) }
            .task { await signIn.observeSignIn() }
            .task(id: scenePhase) {
                if scenePhase == .active { await signIn.recheckAccess() }
            }
    }

    @ViewBuilder private func content(for screen: RootScreen) -> some View {
        switch screen {
        case .updateRequired(let storeURL):
            UpdateRequiredView(storeURL: storeURL)
        case .signIn:
            SignInView(model: signIn)
        case .waiting:
            ColorToken.bg.color
                .ignoresSafeArea()
        case .shell:
            AppShell(router: router)
        }
    }
}

#if DEBUG
#Preview("Signed in, light") {
    RootView(
        update: AppUpdateState(),
        signIn: SignInModel(services: nil, phase: .signedIn(.unlocked)),
        router: AppRouter(api: FixtureAPI().client)
    )
    .preferredColorScheme(.light)
}

#Preview("Signed in, dark") {
    RootView(
        update: AppUpdateState(),
        signIn: SignInModel(services: nil, phase: .signedIn(.unlocked)),
        router: AppRouter(api: FixtureAPI().client)
    )
    .preferredColorScheme(.dark)
}

#Preview("Signed out") {
    RootView(update: AppUpdateState(), signIn: StubSignIn.allow.model(), router: AppRouter(api: nil))
}
#endif
