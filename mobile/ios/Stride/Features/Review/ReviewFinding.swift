/// A failed verdict's note, which Request changes can add to its text.
struct ReviewFinding: Hashable, Sendable {
    let section: VerdictSection
    let note: String
}
