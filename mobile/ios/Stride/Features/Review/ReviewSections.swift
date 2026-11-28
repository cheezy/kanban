import SwiftUI

/// The review's sections, in order.
struct ReviewSections: View {
    let content: ReviewContent
    let conflict: ReviewConflictState?
    let reload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ReviewHeader(content: content)
            if let conflict {
                ReviewConflictNotice(conflict: conflict, reload: reload)
            }
            if content.tooLargeHere {
                ReviewLargeNotice()
            }
            ForEach(content.sections, id: \.self) { section in
                switch section {
                case .summary:
                    ReviewSection(title: .reviewSummary, identifier: "review-summary") {
                        Text(verbatim: content.summary ?? "")
                            .textStyle(.body)
                            .foregroundStyle(ColorToken.ink2.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .verdicts: ReviewVerdictsSection(content: content)
                case .checks: ReviewChecksSection(content: content)
                case .files: ReviewFilesSection(content: content)
                }
            }
        }
    }
}
