import SwiftUI

/// The design's segmented filter, each segment with its count. The segments
/// stack at the accessibility text sizes.
struct NowFilterBar: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Binding var selection: NowFilter
    let count: (NowFilter) -> Int

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 2))
            : AnyLayout(HStackLayout(spacing: 2))
        let outer = RoundedRectangle(cornerRadius: DesignTokens.Radius.lg)

        layout {
            ForEach(NowFilter.allCases) { filter in
                segment(filter)
            }
        }
        .padding(2)
        .background(ColorToken.surfaceSunken.color, in: outer)
        .overlay { outer.strokeBorder(ColorToken.line.color, lineWidth: 1) }
    }

    private func segment(_ filter: NowFilter) -> some View {
        let isSelected = filter == selection
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.md)

        return Button {
            selection = filter
        } label: {
            HStack(spacing: 4) {
                Text(filter.label)
                    .textStyle(.footnote)
                    .fontWeight(.medium)
                    .foregroundStyle((isSelected ? ColorToken.ink : ColorToken.ink2).color)
                    // The UI tests' audit filter finds the label by this.
                    .accessibilityIdentifier("now-filter-label")
                Text(count(filter), format: .number)
                    .textStyle(.code)
                    .foregroundStyle(ColorToken.ink3.color)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background {
                if isSelected {
                    shape.fill(ColorToken.surface.color)
                        .shadow(color: ColorToken.ink.color.opacity(0.08), radius: 1, y: 1)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(filter.label))
        .accessibilityValue(Text(count(filter), format: .number))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("now-filter")
    }
}
