import SwiftUI

/// The notes on the whole file, above the diff.
struct DiffFileNotes: View {
    let notes: [DiffNote]

    var body: some View {
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(notes) { note in
                    DiffNoteRow(note: note, inline: false)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("diff-file-notes")
        }
    }
}
