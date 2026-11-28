import SwiftUI

/// "Reviewer verdicts": how many of the four passed, and a tile each, a
/// failed one with its note.
struct ReviewVerdictsSection: View {
    @Environment(\.dynamicTypeSize) private var typeSize

    let content: ReviewContent

    var body: some View {
        ReviewSection(title: .reviewVerdicts, identifier: "review-verdicts") {
            Text(.reviewPassed(passed: String(content.passed), count: content.tiles.count))
                .textStyle(.footnote)
                .foregroundStyle(ColorToken.ink2.color)
                .accessibilityIdentifier("review-passed")
        } content: {
            // Four tiles at most, so an eager layout: a lazy grid let go of a
            // tile while the text grew, and the audit read it as cut off.
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(content.tiles, id: \.self) { ReviewVerdictTile(tile: $0) }
                }
            } else {
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(Array(content.tileRows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(row, id: \.self) { ReviewVerdictTile(tile: $0) }
                            if row.count == 1 {
                                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                            }
                        }
                    }
                }
            }
            ForEach(Array(content.failedNotes.enumerated()), id: \.offset) { _, note in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "xmark.circle")
                        .accessibilityHidden(true)
                    Text(verbatim: note)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .textStyle(.footnote)
                .foregroundStyle(ColorToken.stBlocked.color)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ColorToken.stBlockedSoft.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("review-failed-note")
            }
        }
    }
}
