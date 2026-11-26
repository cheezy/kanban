import SwiftUI
import UIKit

/// Sets a Stride text style's font, letter spacing, line height and case at
/// the current text size.
struct StrideTextStyleModifier: ViewModifier {
    @Environment(\.dynamicTypeSize) private var textSize

    let style: StrideTextStyle

    func body(content: Content) -> some View {
        let metrics = style.metrics(at: UIContentSizeCategory(textSize))

        content
            .font(style.font)
            .tracking(metrics.tracking)
            .lineSpacing(metrics.lineSpacing)
            .textCase(style.isUppercase ? .uppercase : nil)
    }
}
