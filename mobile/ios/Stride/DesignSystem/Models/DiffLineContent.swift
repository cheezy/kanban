import Foundation
import SwiftUI

/// One line of a diff, as the server sends it.
struct DiffLineContent: Hashable, Sendable {
    let kind: DiffLineKind
    let oldNumber: Int?
    let newNumber: Int?
    let spans: [HighlightedSpan]

    init(kind: DiffLineKind, oldNumber: Int? = nil, newNumber: Int? = nil, spans: [HighlightedSpan]) {
        self.kind = kind
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.spans = spans
    }

    /// The number shown: the old file's for a removed line, the new file's
    /// otherwise.
    var shownNumber: Int? {
        kind == .removed ? oldNumber ?? newNumber : newNumber ?? oldNumber
    }

    var text: String { spans.map(\.text).joined() }

    /// What VoiceOver says before the text, such as "Added, line 42". Nil for a
    /// line with no number, which reads as its text alone.
    func reading(in locale: Locale) -> String? {
        guard let shownNumber else { return nil }

        let number = shownNumber.formatted(.number.grouping(.never).locale(locale))
        let resource: LocalizedStringResource =
            switch kind {
            case .added: .diffLineAdded(line: number)
            case .removed: .diffLineRemoved(line: number)
            case .context, .hunk: .diffLineUnchanged(line: number)
            }

        return resource.resolved(in: locale)
    }

    /// The text with each span in its colour. It is built from plain strings,
    /// so nothing the server sends is read as Markdown or a link.
    func attributedText() -> AttributedString {
        spans.reduce(into: AttributedString()) { line, span in
            var run = AttributedString(span.text)
            run.foregroundColor = (span.kind.ink ?? kind.textInk).color
            line += run
        }
    }
}
