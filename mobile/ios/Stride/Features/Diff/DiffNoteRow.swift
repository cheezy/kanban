import SwiftUI

/// A reviewer's note: under its line inside the diff, indented past the line
/// numbers, or on its own above the diff for a note on the whole file.
struct DiffNoteRow: View {
    @Environment(\.locale) private var locale

    @ScaledMetric(relativeTo: .caption) private var indent = 40

    let note: DiffNote
    /// Inside the diff, under its line.
    var inline = true

    var body: some View {
        Text(note.label(in: locale))
            .textStyle(.footnote)
            .foregroundStyle(ColorToken.stBlocked.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.leading, inline ? indent : 10)
            .padding(.trailing, 10)
            .background(ColorToken.stBlockedSoft.color, in: shape)
            .overlay(alignment: .top) { if inline { border } }
            .overlay(alignment: .bottom) { if inline { border } }
            // Text, not a control, though the screen has actions (W2797).
            .accessibilityRespondsToUserInteraction(false)
            .accessibilityIdentifier(inline ? "diff-note" : "diff-file-note")
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: inline ? 0 : DesignTokens.Radius.lg)
    }

    private var border: some View {
        Rectangle()
            .fill(ColorToken.line.color)
            .frame(height: 1)
    }
}
