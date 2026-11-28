import SwiftUI

/// A review that changed since it loaded: who decided it, or a reload for
/// the new version.
struct ReviewConflictNotice: View {
    @Environment(\.locale) private var locale

    let conflict: ReviewConflictState
    let reload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .textStyle(.callout)
                .fontWeight(.semibold)
                .foregroundStyle(ColorToken.ink.color)
            Text(message)
                .textStyle(.footnote)
                .foregroundStyle(ColorToken.ink2.color)
                .accessibilityIdentifier("review-conflict-message")
            if case .alreadyDecided(_, _, at: let date?) = conflict {
                TimelineView(.everyMinute) { timeline in
                    Text(verbatim: ReviewConflictCopy.when(date, relativeTo: timeline.date, in: locale))
                        .textStyle(.footnote)
                        .foregroundStyle(ColorToken.ink2.color)
                        .accessibilityIdentifier("review-conflict-when")
                }
            }
            if conflict == .resubmitted {
                Button(action: reload) { Text(.reviewReload) }
                    .buttonStyle(.stride)
                    .accessibilityIdentifier("review-reload")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ColorToken.stReviewSoft.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review-conflict")
    }

    private var title: LocalizedStringResource {
        conflict == .resubmitted ? .reviewResubmitted : .reviewAlreadyDecided
    }

    private var message: LocalizedStringResource {
        ReviewConflictCopy.message(for: conflict)
    }
}
