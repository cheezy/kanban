import SwiftUI

/// Why the last attempt failed. The text carries the meaning, the red icon only
/// draws the eye, and VoiceOver reads it out when it appears.
struct SignInProblem: View {
    let text: LocalizedStringResource

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Again when one failure follows another, not only when the first appears.
        .task(id: text.key) {
            AccessibilityNotification.Announcement(String(localized: text)).post()
        }
    }
}
