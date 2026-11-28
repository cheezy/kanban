import SwiftUI

/// One line of a diff: its number, a marker for an added or removed line, and
/// the server's highlighted text, which wraps rather than running off the
/// screen. VoiceOver reads it as, for example, "Added, line 42" and the text.
struct DiffLine: View {
    @Environment(\.locale) private var locale

    /// The 34-point number column of the design and the marker after it.
    @ScaledMetric(relativeTo: .caption) private var gutterWidth = 48

    let line: DiffLineContent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // The marker shares the number's text: on its own it was an
            // element the audit reached despite the line's ignored children,
            // and it failed the thin "−" from a 7-by-16-point crop, though
            // its ink reaches 7.3:1 on a removed line in dark (W2797).
            let gutter = line.gutter(in: locale)
            if gutter.isEmpty {
                Color.clear.frame(width: gutterWidth, height: 1)
            } else {
                Text(verbatim: gutter)
                    .foregroundStyle(line.kind.numberInk.color)
                    .frame(width: gutterWidth, alignment: .trailing)
            }

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
