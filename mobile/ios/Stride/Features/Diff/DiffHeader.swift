import SwiftUI

/// The file's flag, its added and removed lines, its language and its place
/// in the review's files, then its path, which wraps. None of them is a
/// control: the screen's Next file and Previous file actions otherwise make
/// the audit hold each short text to a 44-point hit area (W2797).
struct DiffHeader: View {
    @Environment(\.locale) private var locale

    let content: DiffContent
    let position: LocalizedStringResource?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 8) {
                if content.isFlagged {
                    StatusPill(.reviewFlagged, tone: .blocked)
                        .accessibilityIdentifier("diff-flagged")
                }
                DiffCounts(content: content)
                Text(verbatim: content.language.name(in: locale))
                    .textStyle(.footnote)
                    .foregroundStyle(ColorToken.ink3.color)
                    .accessibilityRespondsToUserInteraction(false)
                    .accessibilityIdentifier("diff-language")
                if let position {
                    Text(position)
                        .textStyle(.code)
                        .foregroundStyle(ColorToken.ink3.color)
                        .accessibilityRespondsToUserInteraction(false)
                        .accessibilityIdentifier("diff-position")
                }
            }

            Text(verbatim: content.path)
                .textStyle(.code)
                .foregroundStyle(ColorToken.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
                // A bare path fails the audit as not human-readable (W2796).
                .accessibilityLabel(Text(verbatim: content.pathReading(in: locale)))
                .accessibilityRespondsToUserInteraction(false)
                .accessibilityIdentifier("diff-path")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("diff-header")
    }
}
