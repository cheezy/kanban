import Foundation
import StrideKit

/// One changed file in the list.
struct ReviewFileRow: Hashable, Sendable, Identifiable {
    /// The file's position in the stored diffs, or nil when no diff is stored.
    let index: Int?
    let path: String
    let additions: Int?
    let deletions: Int?
    let isFlagged: Bool

    var id: String { path }

    /// A file with a stored diff opens it.
    var opens: Bool { index != nil }

    /// What VoiceOver reads for the row: flagged or not, the file's name in
    /// its folder, and its added and removed lines in words, so it neither
    /// reads a bare path nor "plus 120".
    func reading(in locale: Locale) -> String {
        let parts: [String?] = [
            isFlagged ? LocalizedStringResource.reviewFlagged.resolved(in: locale) : nil,
            FilePlace.reading(of: path, in: locale),
            additions.map { LocalizedStringResource.reviewLinesAdded(count: $0).resolved(in: locale) },
            deletions.map { LocalizedStringResource.reviewLinesRemoved(count: $0).resolved(in: locale) },
        ]
        // A narrow list joins with the locale's own separator, "、" in
        // Japanese and Chinese, where ", " would read wrongly.
        return parts.compactMap { $0 }.formatted(.list(type: .and, width: .narrow).locale(locale))
    }

    init(index: Int?, path: String, additions: Int? = nil, deletions: Int? = nil, isFlagged: Bool = false) {
        self.index = index
        self.path = path
        self.additions = additions
        self.deletions = deletions
        self.isFlagged = isFlagged
    }

    init(_ file: Components.Schemas.ReviewFile) {
        index = file.index
        path = file.path
        additions = file.additions
        deletions = file.deletions
        isFlagged = file.flagged
    }
}
