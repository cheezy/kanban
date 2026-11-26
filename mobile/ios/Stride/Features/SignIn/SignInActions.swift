import StrideKit
import SwiftUI

/// The Sign in button, why the last attempt failed, and the way to an account.
struct SignInActions: View {
    let isSigningIn: Bool
    let problem: LocalizedStringResource?
    let signIn: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if let problem {
                SignInProblem(text: problem)
            }

            // Not disabled while signing in, which would grey out the label; the
            // model ignores a second press.
            Button(action: signIn) {
                HStack(spacing: 8) {
                    if isSigningIn {
                        ProgressView()
                            .tint(Color(.systemBackground))
                            .accessibilityHidden(true)
                        Text(.signInWorking)
                    } else {
                        Text(.signInAction)
                    }
                }
                .font(.headline)
                .foregroundStyle(.background)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .controlSize(.large)
            .tint(.primary)

            Text(.signInNote)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)

            // In the text colour and underlined: the system blue reaches only
            // about 4:1 on white, under the 4.5:1 small text needs. A link
            // draws its label in its tint, so the colour is set there.
            Link(destination: StrideWeb.signUp) {
                Text(.signInCreateAccount)
                    .font(.subheadline.weight(.semibold))
                    .underline()
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .tint(.primary)
        }
    }
}
