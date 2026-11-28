import SwiftUI

/// The design's Request changes sheet (Review.dc.html, step "changes"):
/// Cancel, the title and Send across the top, the task, the required "What
/// needs to change" field, a chip for each failed verdict that adds its note,
/// the dictation hint and who gets the note. Send asks for no Face ID.
struct RequestChangesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .body) private var editorHeight = 150

    @Bindable var model: RequestChangesModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                topRow
                task
                field
                chips
                messages
                Text(model.footnote)
                    .textStyle(.footnote)
                    .foregroundStyle(ColorToken.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("changes-footnote")
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(ColorToken.surface.color)
        .presentationDragIndicator(.visible)
        // Notes on their way cannot be dropped, or their answer is lost.
        .interactiveDismissDisabled(model.isSending)
    }

    // MARK: Parts

    /// Cancel, the title and Send in a row, or, at the accessibility text
    /// sizes, the title, Cancel and Send each on its own line, so no word
    /// breaks: on an iPhone in German, Cancel and Send side by side broke
    /// "Abbrechen" in the middle. An eager layout, since the audit fails text
    /// in a `ViewThatFits`.
    @ViewBuilder
    private var topRow: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                title
                cancelButton
                sendButton
            }
        } else {
            HStack(spacing: 8) {
                cancelButton
                Spacer(minLength: 0)
                title
                Spacer(minLength: 0)
                sendButton
            }
        }
    }

    private var title: some View {
        Text(.reviewRequestChanges)
            .textStyle(.headline)
            .foregroundStyle(ColorToken.ink.color)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("sheet-title")
    }

    private var cancelButton: some View {
        Button { dismiss() } label: {
            Text(.nowReplyCancel)
        }
        .buttonStyle(NavButtonStyle())
        .disabled(model.isSending)
        .accessibilityIdentifier("changes-cancel")
    }

    private var sendButton: some View {
        Button {
            Task { await model.send() }
        } label: {
            if model.isSending {
                ProgressView()
                    .accessibilityLabel(Text(.nowReplySend))
            } else {
                Text(.nowReplySend)
            }
        }
        // Off, it reads in ink-3; `.plain` would fade it below 4.5:1.
        .buttonStyle(NavButtonStyle(weight: .semibold))
        .disabled(!model.canSend)
        .accessibilityHint(model.isOffline ? Text(.nowNeedsConnection) : Text(verbatim: ""))
        .accessibilityIdentifier("changes-send")
    }

    /// The identifier and the title, which wraps rather than being cut off,
    /// so the whole title shows as the text grows; at the accessibility sizes
    /// the identifier sits above it.
    private var task: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
        return layout {
            Text(verbatim: model.identifier)
                .textStyle(.code)
                .foregroundStyle(ColorToken.ink3.color)
            Text(verbatim: model.title)
                .textStyle(.footnote)
                .foregroundStyle(ColorToken.ink3.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(.reviewChangesField)
                .textStyle(.footnote)
                .fontWeight(.medium)
                .foregroundStyle(ColorToken.ink2.color)
                .accessibilityHidden(true)

            TextEditor(text: $model.text)
                .textStyle(.body)
                .foregroundStyle(ColorToken.ink.color)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(minHeight: editorHeight)
                .background(ColorToken.surface.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
                .overlay {
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.lg)
                        .strokeBorder(Color(.lineInput), lineWidth: 1)
                }
                .disabled(model.isSending)
                .accessibilityLabel(Text(.reviewChangesField))
                .accessibilityIdentifier("changes-text")
        }
    }

    /// A chip for each failed verdict, then the dictation hint.
    private var chips: some View {
        FlowLayout(spacing: 8) {
            ForEach(model.findings, id: \.self) { finding in
                Button {
                    model.add(finding)
                } label: {
                    Text(.reviewChangesAddFinding(section: finding.section.name.resolved(in: locale)))
                }
                // A chip whose note is in already reads in ink-3, never faded.
                .buttonStyle(ChipButtonStyle())
                .disabled(!model.canAdd(finding))
                .accessibilityIdentifier("changes-add-\(finding.section.rawValue)")
            }

            Label {
                Text(.reviewChangesDictate)
                    .textStyle(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "mic")
                    .accessibilityHidden(true)
            }
            .foregroundStyle(ColorToken.ink3.color)
            .frame(minHeight: 44)
            .accessibilityIdentifier("changes-dictate")
        }
    }

    /// Why Send waits, or why the last send failed.
    @ViewBuilder
    private var messages: some View {
        if model.isTooLong {
            message(.reviewChangesTooLong, ink: .stBlocked, identifier: "changes-too-long")
        }
        if let problem = model.problem {
            message(problem.text, ink: .stBlocked, identifier: "changes-problem")
        }
        if model.isOffline {
            message(.nowNeedsConnection, ink: .ink2, identifier: "changes-offline")
        }
    }

    private func message(_ text: LocalizedStringResource, ink: ColorToken, identifier: String) -> some View {
        Text(text)
            .textStyle(.footnote)
            .foregroundStyle(ink.color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier)
    }
}

#if DEBUG
#Preview("Light") {
    RequestChangesSheet(model: .sample)
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    RequestChangesSheet(model: .sample)
        .preferredColorScheme(.dark)
}

#Preview("German, largest text") {
    RequestChangesSheet(model: .sample)
        .environment(\.locale, Locale(identifier: "de"))
        .dynamicTypeSize(.accessibility5)
}

extension RequestChangesModel {
    static var sample: RequestChangesModel {
        RequestChangesModel(
            identifier: "W2701",
            title: "Show the member count on the organization page",
            agentName: "Claude",
            findings: [ReviewFinding(section: .patterns, note: "One view model reads the store directly.")],
            isOffline: { false },
            send: { _ in nil }
        )
    }
}
#endif
