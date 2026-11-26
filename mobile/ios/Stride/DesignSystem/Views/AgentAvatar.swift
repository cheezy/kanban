import SwiftUI

/// The initials of an agent or a person on the colour of its family: a
/// rounded square for an agent, a circle for a person. VoiceOver reads the
/// name, which is the server's text and shown as is.
struct AgentAvatar: View {
    @Environment(\.locale) private var locale

    @ScaledMetric private var side: CGFloat
    @ScaledMetric private var cornerRadius: CGFloat

    let content: AgentAvatarContent
    let size: AvatarSize

    init(_ content: AgentAvatarContent, size: AvatarSize = .regular) {
        self.content = content
        self.size = size
        _side = ScaledMetric(wrappedValue: size.side, relativeTo: .body)
        _cornerRadius = ScaledMetric(wrappedValue: size.cornerRadius, relativeTo: .body)
    }

    var body: some View {
        let family = content.family

        shape
            .fill(family.fill.color)
            .frame(width: side, height: side)
            .overlay {
                Text(verbatim: content.initials(in: locale) ?? "")
                    .textStyle(textStyle)
                    .fontWeight(.semibold)
                    .foregroundStyle(family.ink.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(2)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: content.name))
    }

    private var shape: AnyShape {
        content.isPerson ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var textStyle: StrideTextStyle {
        switch size {
        case .regular: .subheadline
        case .medium: .footnote
        case .small: .label
        }
    }
}

#if DEBUG
#Preview("Light") {
    SharedViewSamples.avatars.preview
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    SharedViewSamples.avatars.preview
        .preferredColorScheme(.dark)
}
#endif
