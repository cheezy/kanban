import SwiftUI

/// A decision's task identifier, in mono, as a Now card, a Review queue
/// row and the review screen's header show it. The UI tests find it by its
/// identifier.
struct DecisionIdentifier: View {
    let identifier: String

    var body: some View {
        Text(verbatim: identifier)
            .textStyle(.code)
            .foregroundStyle(ColorToken.ink3.color)
            .accessibilityIdentifier("card-identifier")
    }
}
