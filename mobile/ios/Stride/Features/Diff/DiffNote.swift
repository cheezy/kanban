import Foundation
import StrideKit

/// A reviewer's note on a file, at its line or on the file as a whole.
struct DiffNote: Hashable, Sendable, Identifiable {
    /// The note's place in the file's notes, which stays put while the file
    /// shows; `DiffContent` numbers them.
    private(set) var id = 0
    let reviewer: DiffReviewer
    /// The reviewer's explanation, kept as it came, to show as plain text.
    let text: String
    /// The new file's line it belongs after, or nil for the whole file.
    let line: Int?

    init(reviewer: DiffReviewer, text: String, line: Int? = nil) {
        self.reviewer = reviewer
        self.text = text
        self.line = line
    }

    /// A note with no explanation has nothing to show, so it is left out. One
    /// the server could not anchor to a diff line belongs to the whole file.
    init?(_ note: Components.Schemas.ReviewFileNote) {
        guard let text = note.description, !text.isEmpty else { return nil }

        self.init(reviewer: DiffReviewer(category: note.category), text: text, line: note.anchored ? note.line : nil)
    }

    /// The same note at `id` in the file's notes.
    func numbered(_ id: Int) -> DiffNote {
        var note = self
        note.id = id
        return note
    }

    /// "Testing reviewer: the note", with the reviewer in bold. The note is a
    /// plain run, so nothing the server sends is read as Markdown or a link.
    func label(in locale: Locale) -> AttributedString {
        let reviewer = self.reviewer.name.resolved(in: locale)
        var label = AttributedString(LocalizedStringResource.diffNote(reviewer: reviewer, note: text).resolved(in: locale))
        if let range = label.range(of: reviewer) {
            label[range].inlinePresentationIntent = .stronglyEmphasized
        }
        return label
    }
}
