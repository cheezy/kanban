import SwiftUI

/// The design's `.quote`: the server's words on a sunken panel, after the
/// agent's avatar when the card names one.
struct NowQuote: View {
    let text: String
    var agent: AgentAvatarContent?
    var isMonospaced = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let agent {
                AgentAvatar(agent, size: .small)
                    .accessibilityHidden(true)
            }
            Text(verbatim: text)
                .textStyle(isMonospaced ? .code : .subheadline)
                .foregroundStyle(ColorToken.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(ColorToken.surfaceSunken.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
        .accessibilityElement(children: .combine)
    }
}
