import SwiftUI

/// The design's `.toast` after a decision: "Approved. W2702 and W2703 can
/// start." with a checkmark, or "Changes requested. W2701 is waiting for
/// Claude to pick up the changes.", in surface on ink, with Next, which opens
/// the next review. Next is surface and underlined rather than the design's
/// stride-orange, which falls to about 2.6:1 on the dark theme's light ink.
/// VoiceOver reads it out when it appears.
struct DecisionToast: View {
    @Environment(\.locale) private var locale

    let message: LocalizedStringResource
    let kind: DecisionToastKind
    let next: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.xl)
        HStack(alignment: .center, spacing: 12) {
            if kind.showsCheckmark {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(ColorToken.stDoneSoft.color)
                    .accessibilityHidden(true)
            }

            Text(message)
                .textStyle(.subheadline)
                .foregroundStyle(ColorToken.surface.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .accessibilityIdentifier(kind.messageIdentifier)

            Button(action: next) {
                Text(.reviewNext)
                    .textStyle(.subheadline)
                    .fontWeight(.semibold)
                    .underline()
                    .foregroundStyle(ColorToken.surface.color)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("review-next")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background {
            // On the shape alone, so the shadow is not drawn under the text.
            shape.fill(ColorToken.ink.color)
                .shadow(color: ColorToken.ink.color.opacity(0.18), radius: 12, y: 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(kind.toastIdentifier)
        .onAppear {
            AccessibilityNotification.Announcement(message.resolved(in: locale)).post()
        }
    }
}
