import Foundation

/// The agent or person an avatar shows, by the name the server sends.
struct AgentAvatarContent: Hashable, Sendable {
    let name: String
    let isPerson: Bool

    init(name: String, isPerson: Bool = false) {
        self.name = name
        self.isPerson = isPerson
    }

    var family: AgentFamily { AgentFamily(name: name, isPerson: isPerson) }

    /// Two letters: a person's first and last initials, or the first two
    /// letters of an agent's name, so "Claude Opus 5.5" is "CL" and
    /// "Sam Rivera" is "SR". Nil when the name has no letters.
    func initials(in locale: Locale) -> String? {
        let words = name.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: \.isLetter) }
        guard let first = words.first else { return nil }

        let letters =
            if isPerson, let last = words.dropFirst().last {
                [first.first(where: \.isLetter), last.first(where: \.isLetter)].compactMap { $0 }
            } else {
                Array(first.filter(\.isLetter).prefix(2))
            }

        return String(letters).uppercased(with: locale)
    }
}
