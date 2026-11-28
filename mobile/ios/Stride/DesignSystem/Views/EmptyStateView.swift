import SwiftUI

/// Nothing is waiting on the person, or nothing is left to show. Each screen
/// passes its own message and identifier.
struct EmptyStateView: View {
    let message: LocalizedStringResource
    let identifier: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .textStyle(.largeTitle)
                .foregroundStyle(ColorToken.stDone.color)
                .accessibilityHidden(true)
            Text(message)
                .textStyle(.body)
                .foregroundStyle(ColorToken.ink2.color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}
