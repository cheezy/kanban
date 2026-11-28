/// One row of the diff: a line, or a note under the line it is about.
struct DiffRow: Hashable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable {
        case line(DiffLineContent)
        case note(DiffNote)
    }

    /// The row's place in the diff, which stays put while the file shows.
    let id: Int
    let kind: Kind
}
