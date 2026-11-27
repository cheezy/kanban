import SwiftUI

/// Writes a comment on a released task, by keyboard or dictation, and sends
/// it once. Offline it waits, and says it needs a connection.
struct ReplySheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isEditing: Bool
    @ScaledMetric(relativeTo: .body) private var editorHeight = 160

    @Bindable var reply: ReplyModel
    let send: () async -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SheetCloseButton(label: .nowReplyCancel) { dismiss() }

                Text(.nowReply)
                    .textStyle(.title)
                    .foregroundStyle(ColorToken.ink.color)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("sheet-title")

                task

                Text(.nowReplyField)
                    .textStyle(.label)
                    .foregroundStyle(ColorToken.ink2.color)
                    .accessibilityHidden(true)

                TextEditor(text: $reply.text)
                    .textStyle(.body)
                    .foregroundStyle(ColorToken.ink.color)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: editorHeight)
                    .background(ColorToken.surface.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
                    .overlay {
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.lg)
                            .strokeBorder(Color(.lineInput), lineWidth: 1)
                    }
                    .focused($isEditing)
                    .accessibilityLabel(Text(.nowReplyField))
                    .accessibilityIdentifier("reply-text")

                messages

                Button {
                    Task { await send() }
                } label: {
                    Text(.nowReplySend)
                }
                .buttonStyle(StrideButtonStyle(isPrimary: true))
                .disabled(!reply.canSend)
                .accessibilityHint(reply.isOffline ? Text(.nowNeedsConnection) : Text(verbatim: ""))
                .accessibilityIdentifier("reply-send")
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(16)
        }
        .background(ColorToken.bg.color)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(reply.isSending)
        .onAppear { isEditing = true }
    }

    private var task: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !reply.identifier.isEmpty {
                Text(verbatim: reply.identifier)
                    .textStyle(.code)
                    .foregroundStyle(ColorToken.ink3.color)
            }
            Text(verbatim: reply.title)
                .textStyle(.callout)
                .foregroundStyle(ColorToken.ink.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// Why Send waits, or why the last send failed.
    @ViewBuilder
    private var messages: some View {
        if reply.isTooLong {
            message(.nowReplyTooLong, ink: .stBlocked)
        }
        if let problem = reply.problem {
            message(problem.text, ink: .stBlocked)
        }
        if reply.isOffline {
            message(.nowNeedsConnection, ink: .ink2)
        }
    }

    private func message(_ text: LocalizedStringResource, ink: ColorToken) -> some View {
        Text(text)
            .textStyle(.footnote)
            .foregroundStyle(ink.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#if DEBUG
#Preview("Light") {
    ReplySheet(reply: ReplyModel.sample, send: {})
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    ReplySheet(reply: ReplyModel.sample, send: {})
        .preferredColorScheme(.dark)
}

#Preview("German, largest text") {
    ReplySheet(reply: ReplyModel.sample, send: {})
        .environment(\.locale, Locale(identifier: "de"))
        .dynamicTypeSize(.accessibility5)
}

extension ReplyModel {
    static var sample: ReplyModel {
        ReplyModel(cardID: "released-4813", taskID: 4813, identifier: "W104", title: "Add the cache size setting", api: nil) { false }
    }
}
#endif
