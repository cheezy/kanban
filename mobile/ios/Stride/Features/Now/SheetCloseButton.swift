import SwiftUI

/// The plain text button at the top of a Now sheet that closes it. It sits in
/// the sheet's content rather than a bar, as the shell's sheets do, so it
/// grows with the text size and has no glass behind it.
struct SheetCloseButton: View {
    let label: LocalizedStringResource
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .textStyle(.callout)
                .foregroundStyle(ColorToken.ink.color)
                .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
