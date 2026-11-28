import Foundation

/// One verdict tile.
struct ReviewTile: Hashable, Sendable {
    let verdict: Verdict
    /// The reviewer's note, for a failed tile.
    let note: String?
    /// How many criteria were met, on the acceptance tile.
    let criteria: ReviewCriteriaCount?

    /// The verdict in words, with the criteria met on the acceptance tile,
    /// for VoiceOver.
    func reading(in locale: Locale) -> String {
        [verdict.reading(in: locale), criteria?.reading(in: locale)]
            .compactMap { $0 }
            .formatted(.list(type: .and, width: .narrow).locale(locale))
    }
}
