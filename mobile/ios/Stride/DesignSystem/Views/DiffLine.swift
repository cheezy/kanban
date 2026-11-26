import SwiftUI

/// One line of a diff: its number, a marker for an added or removed line, and
/// the server's highlighted text, which wraps rather than running off the
/// screen. VoiceOver reads it as, for example, "Added, line 42" and the text.
struct DiffLine: View {
    @Environment(\.locale) private var locale

    @ScaledMetric(relativeTo: .caption) private var numberWidth = 34

    let line: DiffLineContent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: line.shownNumber.map { $0.formatted(.number.grouping(.never).locale(locale)) } ?? "")
                .foregroundStyle(line.kind.numberInk.color)
                .frame(width: numberWidth, alignment: .trailing)

            Text(verbatim: line.kind.marker)
                .foregroundStyle(line.kind.numberInk.color)

            Text(line.attributedText())
                .foregroundStyle(line.kind.textInk.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textStyle(.code)
        .padding(.trailing, 8)
        .background(line.kind.background?.color ?? .clear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: line.reading(in: locale) ?? line.text))
        .accessibilityValue(Text(verbatim: line.reading(in: locale) == nil ? "" : line.text))
    }
}

#if DEBUG
#Preview("Light") {
    SharedViewSamples.diff.preview
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    SharedViewSamples.diff.preview
        .preferredColorScheme(.dark)
}

#Preview("German, largest text") {
    SharedViewSamples.diff.preview
        .environment(\.locale, Locale(identifier: "de"))
        .dynamicTypeSize(.accessibility5)
}
#endif
