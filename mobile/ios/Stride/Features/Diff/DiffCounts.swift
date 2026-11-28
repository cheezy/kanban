import SwiftUI

/// The file's added and removed lines, "+3 −1", read as "3 lines added and 1
/// line removed". A binary file has neither, so nothing shows.
struct DiffCounts: View {
    @Environment(\.locale) private var locale

    let content: DiffContent

    var body: some View {
        if let reading = content.countsReading(in: locale) {
            HStack(spacing: 6) {
                if let additions = content.additions {
                    Text(verbatim: LineCountText.added(additions, in: locale))
                        .foregroundStyle(ColorToken.stDone.color)
                }
                if let deletions = content.deletions {
                    Text(verbatim: LineCountText.removed(deletions, in: locale))
                        .foregroundStyle(ColorToken.stBlocked.color)
                }
            }
            .textStyle(.code)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: reading))
            .accessibilityAddTraits(.isStaticText)
            // Not a control, though the screen has actions (W2797).
            .accessibilityRespondsToUserInteraction(false)
            .accessibilityIdentifier("diff-counts")
        }
    }
}
