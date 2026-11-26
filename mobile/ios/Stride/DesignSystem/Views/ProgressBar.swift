import SwiftUI

/// A goal's tasks as segments: done, in review, in progress and blocked in
/// their colours, and the rest empty. VoiceOver reads the counts, such as
/// "4 of 9 done, 1 in review, 2 in progress".
struct ProgressBar: View {
    @Environment(\.locale) private var locale

    static let gap: CGFloat = 3

    let counts: ProgressCounts

    var body: some View {
        GeometryReader { proxy in
            let segments = counts.segments
            let widths = ProgressSegment.widths(of: segments, in: proxy.size.width, gap: Self.gap)

            HStack(spacing: Self.gap) {
                if segments.isEmpty {
                    piece(.toDo)
                } else {
                    ForEach(Array(zip(segments, widths)), id: \.0.kind) { segment, width in
                        piece(segment.kind)
                            .frame(width: width)
                    }
                }
            }
        }
        .frame(height: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: counts.reading(in: locale)))
    }

    private func piece(_ kind: ProgressSegment.Kind) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(kind.fill.color)
            .overlay {
                if kind.hasBorder {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(ColorToken.line2.color, lineWidth: 1)
                }
            }
    }
}

#if DEBUG
#Preview("Light") {
    SharedViewSamples.progress.preview
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    SharedViewSamples.progress.preview
        .preferredColorScheme(.dark)
}
#endif
