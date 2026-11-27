import SwiftUI

/// A card's buttons, side by side, or one above another at the accessibility
/// text sizes. Offline they wait, and say they need a connection.
struct NowCardActions: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let actions: [NowAction]
    let isOffline: Bool
    let perform: (NowAction) -> Void

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 8))

        VStack(alignment: .leading, spacing: 6) {
            layout {
                ForEach(actions, id: \.self) { action in
                    Button { perform(action) } label: { Text(action.label) }
                        .buttonStyle(StrideButtonStyle(isPrimary: action.isPrimary))
                        .accessibilityHint(isOffline ? Text(.nowNeedsConnection) : Text(verbatim: ""))
                }
            }
            .disabled(isOffline)

            if isOffline {
                Text(.nowNeedsConnection)
                    .textStyle(.footnote)
                    .foregroundStyle(ColorToken.ink2.color)
                    .accessibilityHidden(true)
            }
        }
        .padding(.top, 4)
    }
}
