import Foundation
import StrideKit

/// How many acceptance criteria the reviewer marked met, of how many.
struct ReviewCriteriaCount: Hashable, Sendable {
    let met: Int
    let count: Int

    init(met: Int, count: Int) {
        self.met = met
        self.count = count
    }

    /// The reviewer's results, or nil when it gave no status for any of them.
    init?(_ criteria: [Components.Schemas.ReviewAcceptanceCriterion]) {
        guard criteria.contains(where: { $0.status != nil }) else { return nil }

        met = criteria.count(where: { $0.status == "met" })
        count = criteria.count
    }

    /// "4/4", as the tile shows it.
    var text: LocalizedStringResource { .reviewCriteriaCount(met: String(met), count: count) }

    /// "4 of 4 criteria met", for VoiceOver.
    func reading(in locale: Locale) -> String {
        LocalizedStringResource.reviewCriteriaMet(met: String(met), count: count).resolved(in: locale)
    }
}
