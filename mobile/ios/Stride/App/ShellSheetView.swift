import SwiftUI

/// The sheet a corner button opens, with a Close button and its title until
/// its own screen is built. Both sit in the sheet's content rather than a
/// navigation bar: bar items keep their size whatever the text size, and the
/// glass behind a bar button fails the contrast audit.
struct ShellSheetView: View {
    @Environment(\.dismiss) private var dismiss

    let sheet: ShellSheet

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Button { dismiss() } label: {
                    Text(.shellClose)
                        .textStyle(.callout)
                        .foregroundStyle(ColorToken.ink.color)
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text(sheet.title)
                    .textStyle(.title)
                    .foregroundStyle(ColorToken.ink.color)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("sheet-title")
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .background(ColorToken.bg.color)
        .presentationDragIndicator(.visible)
    }
}

#if DEBUG
#Preview("Light") {
    ShellSheetView(sheet: .newTask)
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    ShellSheetView(sheet: .settings)
        .preferredColorScheme(.dark)
}
#endif
