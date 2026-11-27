import SwiftUI

/// What the last card action came to, above the cards, with a button that
/// closes it. VoiceOver reads it out when it appears.
struct NowNoticeView: View {
    @Environment(\.locale) private var locale

    let notice: NowNotice
    let close: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: notice.isProblem ? "exclamationmark.circle" : "checkmark.circle")
                .foregroundStyle(ink.color)
                .accessibilityHidden(true)

            Text(notice.text)
                .textStyle(.subheadline)
                .foregroundStyle(ColorToken.ink.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("now-notice")

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
            AccessibilityNotification.Announcement(notice.text.resolved(in: locale)).post()
        }
    }

    private var ink: ColorToken { notice.isProblem ? .stBlocked : .stDone }
    private var fill: ColorToken { notice.isProblem ? .stBlockedSoft : .stDoneSoft }
}
