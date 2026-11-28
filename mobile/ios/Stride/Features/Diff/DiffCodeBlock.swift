import SwiftUI

/// The diff, read-only: each line with its number and the server's
/// highlighting, wrapped rather than cut, with a note under the line it is
/// about. Says when the diff was cut at the server's cap, or has no lines.
struct DiffCodeBlock: View {
    let content: DiffContent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // An eager stack: the server caps a diff at 500 lines, and the
            // accessibility audit fails text a lazy stack lets go of.
            VStack(alignment: .leading, spacing: 0) {
                if content.isEmpty {
                    Text(.diffEmpty)
                        .textStyle(.footnote)
                        .foregroundStyle(ColorToken.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier("diff-empty")
                        .accessibilityRespondsToUserInteraction(false)
                } else {
                    ForEach(content.rows) { row in
                        switch row.kind {
                        case .line(let line):
                            // Under the swipe, so not a control (W2797).
                            DiffLine(line: line)
                                .accessibilityIdentifier("diff-line")
                                .accessibilityRespondsToUserInteraction(false)
                        case .note(let note):
                            DiffNoteRow(note: note)
                        }
                    }
                }
            }
            .padding(.vertical, 6)
            .background(ColorToken.surface.color)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.lg)
                    .strokeBorder(ColorToken.line.color)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(.diffRegion(name: content.name)))
            .accessibilityIdentifier("diff-code")

            if content.isTruncated {
                Text(.diffCapped)
                    .textStyle(.footnote)
                    .foregroundStyle(ColorToken.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("diff-capped")
            }
        }
    }
}

