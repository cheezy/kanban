import SwiftUI

// The review screen's sections under its header: the verdict tiles, tests
// and checks, and the files, in the order of design section 6.4.

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
                    ForEach(Array(stride(from: 0, to: content.tiles.count, by: 2)), id: \.self) { start in
                        GridRow {
                            ReviewVerdictTile(tile: content.tiles[start])
                            if start + 1 < content.tiles.count {
                                ReviewVerdictTile(tile: content.tiles[start + 1])
                            } else {
                                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                            }
                        }
                    }
                }
            }
            ForEach(content.tiles.filter { $0.note != nil }, id: \.self) { tile in
                if let note = tile.note {
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
}

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

/// "Tests and checks", "Security review" and "Exploratory testing", each a
/// label and its result.
struct ReviewChecksSection: View {
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize

    let content: ReviewContent

    var body: some View {
        ReviewSection(title: .reviewChecks, identifier: "review-checks") {
            if let pitfalls = content.pitfalls {
                ReviewResultRow(label: .verdictSectionPitfalls) {
                    VerdictPill(verdict: pitfalls, text: content.pitfallsText(in: locale))
                }
            }
            ReviewResultRow(label: .reviewProjectChecks) { result(content.checksResult(in: locale)) }
            ReviewResultRow(label: .reviewSecurity) { result(content.securityResult(in: locale)) }
                .accessibilityIdentifier("review-security")
            ReviewResultRow(label: .reviewExploratory) { result(content.exploratoryResult(in: locale)) }
                .accessibilityIdentifier("review-exploratory")
        }
    }

    private func result(_ value: ReviewResult) -> some View {
        Text(verbatim: value.text)
            .textStyle(.callout)
            .fontWeight(.medium)
            .foregroundStyle(value.tone.color)
            // Under its label once the row stacks, so aligned with it.
            .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A label on the left and its result on the right, stacked under it at
/// the accessibility text sizes.
struct ReviewResultRow<Result: View>: View {
    let label: LocalizedStringResource
    @ViewBuilder let result: Result

    @Environment(\.dynamicTypeSize) private var typeSize

    /// Side by side, with the label wrapping first, and stacked at the
    /// accessibility sizes. The choice follows the text size rather than
    /// what fits, so the row does not swap layouts while the text grows.
    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        layout {
            name
                .frame(maxWidth: stacked ? nil : .infinity, alignment: .leading)
            result
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var name: some View {
        Text(label)
            .textStyle(.callout)
            .foregroundStyle(ColorToken.ink.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// "Files · N", flagged first. A file with a stored diff opens it.
struct ReviewFilesSection: View {
    let content: ReviewContent

    var body: some View {
        ReviewSection(title: .reviewFiles(count: content.files.count), identifier: "review-files") {
            if content.hasFlaggedFiles {
                Text(.reviewFlaggedFirst)
                    .textStyle(.footnote)
                    .foregroundStyle(ColorToken.ink2.color)
                    .accessibilityIdentifier("review-flagged-first")
            }
        } content: {
            // Eager: one task's files, and a lazy stack lets go of rows the
            // Dynamic Type audit pushes off the screen.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(content.files) { file in
                    if let index = file.index {
                        NavigationLink(value: AppRoute.reviewFile(content.taskID, index: index, path: file.path)) {
                            ReviewFileRowView(file: file)
                        }
                        .buttonStyle(.plain)
                    } else {
                        ReviewFileRowView(file: file)
                    }
                    if file.id != content.files.last?.id {
                        Divider().overlay(ColorToken.line.color)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("review-file-rows")
        }
    }
}

/// One file: flagged or not, its path and its added and removed lines.
struct ReviewFileRowView: View {
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize

    let file: ReviewFileRow

    var body: some View {
        Group {
            // At the accessibility sizes the path takes the full width, with
            // the flag above it and the counts below; beside them it broke
            // every few characters.
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    flag
                    path
                    HStack(spacing: 8) { counts }
                }
                .padding(.vertical, 8)
            } else {
                HStack(spacing: 8) {
                    flag
                    path
                    counts
                }
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: file.reading(in: locale)))
        .accessibilityIdentifier(file.isFlagged ? "review-file-flagged" : "review-file")
    }

    @ViewBuilder private var flag: some View {
        if file.isFlagged {
            StatusPill(.reviewFlagged, tone: .blocked)
        }
    }

    private var path: some View {
        Text(verbatim: file.path)
            .textStyle(.code)
            .foregroundStyle(ColorToken.ink.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var counts: some View {
        if let additions = file.additions {
            Text(verbatim: "+\(additions)")
                .textStyle(.code)
                .foregroundStyle(ColorToken.stDone.color)
        }
        if let deletions = file.deletions {
            Text(verbatim: "−\(deletions)")
                .textStyle(.code)
                .foregroundStyle(ColorToken.stBlocked.color)
        }
        if file.opens {
            Image(systemName: "chevron.right")
                .foregroundStyle(ColorToken.ink3.color)
                .accessibilityHidden(true)
        }
    }
}
