import Foundation
import StrideKit

/// What the file screen shows of one changed file: its header, the diff's
/// lines with each anchored note under its line, and the notes on the whole
/// file. The server's text is kept as it came, to be shown as plain text.
struct DiffContent: Hashable, Sendable {
    let path: String
    let language: DiffLanguage
    let additions: Int?
    let deletions: Int?
    let isFlagged: Bool
    /// The stored diff was cut at the server's cap of 500 lines.
    let isTruncated: Bool
    let rows: [DiffRow]
    /// Notes on the file as a whole, or on a line the diff does not show.
    let fileNotes: [DiffNote]

    init(
        path: String,
        language: DiffLanguage,
        additions: Int? = nil,
        deletions: Int? = nil,
        isFlagged: Bool = false,
        isTruncated: Bool = false,
        lines: [DiffLineContent],
        notes: [DiffNote] = []
    ) {
        self.path = path
        self.language = language
        self.additions = additions
        self.deletions = deletions
        self.isFlagged = isFlagged
        self.isTruncated = isTruncated
        (rows, fileNotes) = Self.place(notes, in: lines)
    }

    /// The file's name, after its last slash.
    var name: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// What VoiceOver reads for the path: the name in its folder.
    func pathReading(in locale: Locale) -> String {
        FilePlace.reading(of: path, in: locale)
    }

    /// The diff has no lines to show, as for a binary file.
    var isEmpty: Bool { rows.isEmpty }

    /// What VoiceOver reads for the counts, such as "3 lines added, 1 line
    /// removed", rather than "plus 3".
    func countsReading(in locale: Locale) -> String? {
        let parts = [
            additions.map { LocalizedStringResource.reviewLinesAdded(count: $0).resolved(in: locale) },
            deletions.map { LocalizedStringResource.reviewLinesRemoved(count: $0).resolved(in: locale) },
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.formatted(.list(type: .and).locale(locale))
    }

    /// Each anchored note goes under the first line whose new number is its
    /// line, in the reviewer's order; a note whose line the diff lacks goes
    /// with the notes on the whole file.
    private static func place(_ notes: [DiffNote], in lines: [DiffLineContent]) -> ([DiffRow], [DiffNote]) {
        var byLine: [Int: [DiffNote]] = [:]
        var fileNotes: [DiffNote] = []
        let shown = Set(lines.compactMap(\.newNumber))
        for note in notes.enumerated().map({ $1.numbered($0) }) {
            if let line = note.line, shown.contains(line) {
                byLine[line, default: []].append(note)
            } else {
                fileNotes.append(note)
            }
        }

        var rows: [DiffRow] = []
        for line in lines {
            rows.append(DiffRow(id: rows.count, kind: .line(line)))
            guard let number = line.newNumber, let notes = byLine.removeValue(forKey: number) else { continue }

            for note in notes {
                rows.append(DiffRow(id: rows.count, kind: .note(note)))
            }
        }
        return (rows, fileNotes)
    }
}

extension DiffContent {
    init(_ file: Components.Schemas.ReviewFileDiff) {
        self.init(
            path: file.path,
            language: DiffLanguage(apiValue: file.language.value1?.rawValue ?? file.language.value2),
            additions: file.additions,
            deletions: file.deletions,
            isFlagged: file.flagged,
            isTruncated: file.truncated,
            lines: file.lines.map(DiffLineContent.init),
            notes: file.notes.compactMap(DiffNote.init)
        )
    }
}

extension DiffLineContent {
    init(_ line: Components.Schemas.ReviewDiffLine) {
        self.init(
            kind: DiffLineKind(apiValue: line.kind.value1?.rawValue ?? line.kind.value2),
            oldNumber: line.old,
            newNumber: line.new,
            spans: line.spans.map(HighlightedSpan.init)
        )
    }
}

extension HighlightedSpan {
    init(_ span: Components.Schemas.ReviewDiffSpan) {
        self.init(span.text, kind: HighlightClass(apiValue: span._class.value1?.rawValue ?? span._class.value2))
    }
}
