import SwiftUI

/// A task's priority as a coloured dot, which VoiceOver reads in words, such
/// as "Critical priority".
struct PriorityDot: View {
    @Environment(\.locale) private var locale

    @ScaledMetric(relativeTo: .footnote) private var side = 7

    let priority: Priority

    var body: some View {
        Circle()
            .fill(priority.color.color)
            .frame(width: side, height: side)
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: priority.label.resolved(in: locale)))
            // Read as text, not a control, so the audit does not hold the
            // 7-point dot to a tap target's size.
            .accessibilityAddTraits(.isStaticText)
    }
}

#if DEBUG
#Preview("Light and dark") {
    HStack(spacing: 24) {
        ForEach(Priority.allCases, id: \.self) { PriorityDot(priority: $0) }
    }
    .padding()
    .background(Color(.surface))
}
#endif
