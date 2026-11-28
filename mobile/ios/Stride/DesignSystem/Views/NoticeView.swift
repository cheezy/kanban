import SwiftUI

/// A notice of what an action came to, with a button that closes it: a
/// confirmation on `st-done-soft`, or a problem on `st-blocked-soft`, in ink.
/// VoiceOver reads it out when it appears.
struct NoticeView: View {
    @Environment(\.locale) private var locale

    let text: LocalizedStringResource
    let isProblem: Bool
    /// The accessibility identifier of the notice's text.
    let identifier: String
    let close: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: isProblem ? "exclamationmark.circle" : "checkmark.circle")
                .foregroundStyle(ink.color)
                .accessibilityHidden(true)

            Text(text)
                .textStyle(.subheadline)
                .foregroundStyle(ColorToken.ink.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(identifier)

            Button(action: close) {
                Image(systemName: "xmark")
                    .foregroundStyle(ColorToken.ink2.color)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(.shellClose))
        }
        .padding(.leading, 12)
        .background(fill.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
        .accessibilityElement(children: .contain)
        .onAppear {
            AccessibilityNotification.Announcement(text.resolved(in: locale)).post()
        }
    }

    private var ink: ColorToken { isProblem ? .stBlocked : .stDone }
    private var fill: ColorToken { isProblem ? .stBlockedSoft : .stDoneSoft }
}
