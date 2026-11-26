/// A run of a diff line's text and the kind of token the server says it is.
struct HighlightedSpan: Hashable, Sendable {
    let text: String
    let kind: HighlightClass

    init(_ text: String, kind: HighlightClass = .plain) {
        self.text = text
        self.kind = kind
    }
}
