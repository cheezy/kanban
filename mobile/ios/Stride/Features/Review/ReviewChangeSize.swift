import Foundation
import StrideKit

/// The size of a change, as the review's `size` gives it, for the notice on a
/// change too large to approve here: "14 files and 652 changed lines".
struct ReviewChangeSize: Hashable, Sendable {
    /// Nil when the server could not count the files.
    let files: Int?
    let changedLines: Int

    init(files: Int?, changedLines: Int) {
        self.files = files.map { max(0, $0) }
        self.changedLines = max(0, changedLines)
    }

    init(_ size: Components.Schemas.ReviewSize) {
        self.init(files: size.filesUnknown ? nil : size.files, changedLines: size.changedLines)
    }

    /// "14 files and 652 changed lines", or "652 changed lines" when the
    /// files could not be counted.
    func text(in locale: Locale) -> String {
        let lines = LocalizedStringResource.reviewLargeLines(count: changedLines).resolved(in: locale)
        guard let files else { return lines }

        let fileCount = LocalizedStringResource.reviewQueueFiles(count: files).resolved(in: locale)
        return LocalizedStringResource.reviewLargeSize(files: fileCount, lines: lines).resolved(in: locale)
    }
}
