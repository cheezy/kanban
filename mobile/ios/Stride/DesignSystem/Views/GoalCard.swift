import SwiftUI

/// A goal: its identifier, title and progress, how many of its tasks wait on
/// the reader and whether its hook failed.
struct GoalCard: View {
    @Environment(\.locale) private var locale

    let content: GoalCardContent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: content.identifier)
                    .textStyle(.code)
                    .foregroundStyle(ColorToken.ink3.color)
                Spacer(minLength: 8)
                // The bar reads the counts in full, so VoiceOver skips the fraction.
                Text(verbatim: LocalizedStringResource.goalProgressFraction(done: content.progress.done, count: content.progress.total).resolved(in: locale))
                    .textStyle(.code)
                    .foregroundStyle(ColorToken.ink2.color)
                    .accessibilityHidden(true)
            }

            Text(verbatim: content.title)
                .textStyle(.callout)
                .foregroundStyle(ColorToken.ink.color)
                .fixedSize(horizontal: false, vertical: true)

            ProgressBar(counts: content.progress)

            if content.waitingOnYou > 0 || content.hookFailed {
                FlowLayout(spacing: 6) {
                    if content.waitingOnYou > 0 {
                        StatusPill(.goalWaitingOnYou(count: content.waitingOnYou), tone: .review)
                    }
                    if content.hookFailed {
                        StatusPill(.goalHookFailed, tone: .blocked)
                    }
                }
            }
        }
        .cardChrome()
        .accessibilityElement(children: .contain)
    }
}

#if DEBUG
#Preview("Light") {
    SharedViewSamples.goals.preview
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    SharedViewSamples.goals.preview
        .preferredColorScheme(.dark)
}

#Preview("German, largest text") {
    SharedViewSamples.goals.preview
        .environment(\.locale, Locale(identifier: "de"))
        .dynamicTypeSize(.accessibility5)
}
#endif
