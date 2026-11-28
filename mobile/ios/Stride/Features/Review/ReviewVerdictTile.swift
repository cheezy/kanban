import SwiftUI

/// One verdict tile: its section and a check, a cross or a dash, and on the
/// acceptance tile how many criteria were met, such as "4/4".
struct ReviewVerdictTile: View {
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize

    @ScaledMetric(relativeTo: .body) private var minHeight = 40

    let tile: ReviewTile

    var body: some View {
        // Stacked at the accessibility sizes, where a name beside the mark
        // and the count broke mid-word ("Accepta" / "nce").
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))
        layout {
            Image(systemName: tile.verdict.state.symbol)
                .fontWeight(.bold)
                .accessibilityHidden(true)
            Text(tile.verdict.section.name)
                .textStyle(.callout)
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)
            if let criteria = tile.criteria {
                Text(criteria.text)
                    .textStyle(.code)
            }
        }
        .foregroundStyle(tile.verdict.state.ink.color)
        .padding(.horizontal, 10)
        .padding(.vertical, typeSize.isAccessibilitySize ? 8 : 0)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
        .background(tile.verdict.state.fill.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: tile.reading(in: locale)))
        // Its own name on the acceptance tile, whose mono count an iPad's
        // audit misjudges (isOnCriteriaTile in the UI tests).
        .accessibilityIdentifier(tile.criteria == nil ? "review-tile" : "review-criteria-tile")
    }
}
