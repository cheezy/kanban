import AuthenticationServices
import StrideKit
import SwiftUI

/// The first screen of a device that is not signed in, and of a person whose
/// plan does not include the app.
///
/// The points sit in the middle and the actions at the foot. At the
/// accessibility text sizes the whole screen scrolls, and on an iPad the column
/// keeps a readable width.
struct SignInView: View {
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.dynamicTypeSize) private var textSize

    let model: SignInModel

    var body: some View {
        GeometryReader { screen in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Spacer(minLength: 0)

                    SignInHeader()

                    VStack(alignment: .leading, spacing: 16) {
                        SignInPoint(text: model.reviewPoint, color: .indigo)
                        SignInPoint(text: .signInPointUnblock, color: .red)
                        SignInPoint(text: .signInPointReady, color: .blue)
                    }

                    Spacer(minLength: 0)

                    if model.phase == .locked {
                        LockedPanel()
                    } else {
                        SignInActions(isSigningIn: model.isSigningIn, problem: model.problem) {
                            Task { await model.signIn(through: webAuthenticationSession) }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: textSize.isAccessibilitySize ? 640 : 480)
                .frame(maxWidth: .infinity, minHeight: screen.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background()
    }
}

#if DEBUG
#Preview("Light") {
    SignInView(model: StubSignIn.allow.model())
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    SignInView(model: StubSignIn.allow.model())
        .preferredColorScheme(.dark)
}

#Preview("Locked") {
    SignInView(model: SignInModel(services: nil, phase: .locked))
}

#Preview("A failed attempt") {
    SignInView(model: SignInModel(services: nil, phase: .signedOut(.network)))
}

#Preview("German, largest text") {
    SignInView(model: StubSignIn.allow.model())
        .environment(\.locale, Locale(identifier: "de"))
        .dynamicTypeSize(.accessibility5)
}
#endif
