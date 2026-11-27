import StrideKit
import SwiftUI

/// A failed goal's last after_goal attempt: its exit code and how long the
/// hook ran, and never its output (decision 9 of the design).
struct HookAttemptView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    let attempt: HookAttemptModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SheetCloseButton(label: .shellClose) { dismiss() }

                Text(.nowAttemptTitle)
                    .textStyle(.title)
                    .foregroundStyle(ColorToken.ink.color)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("sheet-title")

                if !attempt.identifier.isEmpty {
                    Text(verbatim: attempt.identifier)
                        .textStyle(.code)
                        .foregroundStyle(ColorToken.ink3.color)
                }

                content

                Text(.nowAttemptNoOutput)
                    .textStyle(.footnote)
                    .foregroundStyle(ColorToken.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(16)
        }
        .background(ColorToken.bg.color)
        .presentationDragIndicator(.visible)
        .task { await attempt.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch attempt.state {
        case .loading:
            ProgressView {
                Text(.nowAttemptLoading)
                    .textStyle(.footnote)
                    .foregroundStyle(ColorToken.ink2.color)
            }
            .frame(maxWidth: .infinity, minHeight: 88)
        case .loaded(let hook):
            VStack(spacing: 0) {
                row(.nowAttemptExitCode, value: hook.exitCodeText(in: locale))
                Divider().overlay(ColorToken.line.color)
                row(.nowAttemptDuration, value: hook.durationText(in: locale))
            }
            .padding(.horizontal, 14)
            .background(ColorToken.surface.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.lg)
                    .strokeBorder(ColorToken.line.color, lineWidth: 1)
            }
        case .unavailable:
            Text(.nowAttemptUnavailable)
                .textStyle(.subheadline)
                .foregroundStyle(ColorToken.stBlocked.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A name on the left and its value on the right, or one above the other
    /// when they do not fit side by side.
    private func row(_ name: LocalizedStringResource, value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                rowName(name)
                Spacer(minLength: 12)
                rowValue(value)
            }
            VStack(alignment: .leading, spacing: 2) {
                rowName(name)
                rowValue(value)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("attempt-row")
    }

    private func rowName(_ name: LocalizedStringResource) -> some View {
        Text(name)
            .textStyle(.subheadline)
            .foregroundStyle(ColorToken.ink2.color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func rowValue(_ value: String) -> some View {
        Text(verbatim: value)
            .textStyle(.code)
            .foregroundStyle(ColorToken.ink.color)
    }
}

#if DEBUG
private struct HookAttemptPreview: View {
    @State private var attempt = HookAttemptModel(cardID: "hook-4815", goalID: 4790, identifier: "G88", api: FixtureAPI().client)

    var body: some View {
        HookAttemptView(attempt: attempt)
    }
}

#Preview("Light") {
    HookAttemptPreview().preferredColorScheme(.light)
}

#Preview("Dark") {
    HookAttemptPreview().preferredColorScheme(.dark)
}

#Preview("German, largest text") {
    HookAttemptPreview()
        .environment(\.locale, Locale(identifier: "de"))
        .dynamicTypeSize(.accessibility5)
}
#endif
