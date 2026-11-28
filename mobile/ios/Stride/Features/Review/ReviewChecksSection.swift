import SwiftUI

/// "Tests and checks", "Security review" and "Exploratory testing", each a
/// label and its result.
struct ReviewChecksSection: View {
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize

    let content: ReviewContent

    var body: some View {
        ReviewSection(title: .reviewChecks, identifier: "review-checks") {
            if let pitfalls = content.pitfalls {
                ReviewResultRow(label: .verdictSectionPitfalls) {
                    VerdictPill(verdict: pitfalls, text: content.pitfallsText(in: locale))
                }
            }
            ReviewResultRow(label: .reviewProjectChecks) { result(content.checksResult(in: locale)) }
            ReviewResultRow(label: .reviewSecurity) { result(content.securityResult(in: locale)) }
                .accessibilityIdentifier("review-security")
            ReviewResultRow(label: .reviewExploratory) { result(content.exploratoryResult(in: locale)) }
                .accessibilityIdentifier("review-exploratory")
        }
    }

    private func result(_ value: ReviewResult) -> some View {
        Text(verbatim: value.text)
            .textStyle(.callout)
            .fontWeight(.medium)
            .foregroundStyle(value.tone.color)
            // Under its label once the row stacks, so aligned with it.
            .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
            .fixedSize(horizontal: false, vertical: true)
    }
}
