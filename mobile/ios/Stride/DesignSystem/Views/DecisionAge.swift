import SwiftUI

/// How long a decision has waited, short on screen and in words to
/// VoiceOver, redrawn each minute.
struct DecisionAge: View {
    @Environment(\.locale) private var locale

    let content: DecisionCardContent

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(verbatim: content.age(at: context.date, in: locale) ?? "")
                .textStyle(.code)
                .foregroundStyle(ColorToken.ink3.color)
                .accessibilityLabel(Text(verbatim: content.age(at: context.date, in: locale, width: .wide) ?? ""))
                .accessibilityIdentifier("card-age")
        }
    }
}
