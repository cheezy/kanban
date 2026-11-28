import SwiftUI

/// One file: flagged or not, its path and its added and removed lines.
struct ReviewFileRowView: View {
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize

    let file: ReviewFileRow

    var body: some View {
        // At the accessibility sizes the path takes the full width, with the
        // flag above it and the counts below; beside them it broke every few
        // characters.
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))
        layout {
            flag
            path
            HStack(spacing: 8) { counts }
        }
        .padding(.vertical, stacked ? 8 : 0)
        .frame(minHeight: 44)
        .contentShape(.rect)
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
            Text(verbatim: LineCountText.added(additions, in: locale))
                .textStyle(.code)
                .foregroundStyle(ColorToken.stDone.color)
        }
        if let deletions = file.deletions {
            Text(verbatim: LineCountText.removed(deletions, in: locale))
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
