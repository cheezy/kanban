import SwiftUI
import UIKit

/// Stride's text styles, in the token families Geist and Geist Mono. Each one
/// scales with Dynamic Type from the system style it follows, up to the
/// accessibility sizes. Show text in one with `.textStyle(_:)`, which also sets
/// its letter spacing, line height and case.
///
/// Every style's family, size, weight, letter spacing, line height and case
/// come from its `text_style` token through the generated
/// `DesignTokens.TextStyles`; only how it grows with the reader's text size,
/// `scalesLike`, is set here.
enum StrideTextStyle: CaseIterable, Sendable {
    /// A screen's name at its top, as on the Sign in screen.
    case largeTitle
    /// A heading inside a screen.
    case title
    /// A navigation title, or a short heading above its text.
    case headline
    /// Running text and controls.
    case body
    /// A card's title.
    case callout
    /// Text under a title.
    case subheadline
    /// Notes and details.
    case footnote
    /// A small upper-case label in Geist Mono, such as a group's name.
    case label
    /// A task identifier, a path or code, in Geist Mono.
    case code

    /// The style's token.
    var token: DesignTokens.TextStyle {
        switch self {
        case .largeTitle: DesignTokens.TextStyles.largeTitle
        case .title: DesignTokens.TextStyles.title
        case .headline: DesignTokens.TextStyles.headline
        case .body: DesignTokens.TextStyles.body
        case .callout: DesignTokens.TextStyles.callout
        case .subheadline: DesignTokens.TextStyles.subheadline
        case .footnote: DesignTokens.TextStyles.footnote
        case .label: DesignTokens.TextStyles.label
        case .code: DesignTokens.TextStyles.code
        }
    }

    var family: String { token.family }

    /// The size at the default text size, in points.
    var size: CGFloat { token.size }

    var weight: Font.Weight { token.weight }

    /// Letter spacing as a share of the size, as CSS's `em`.
    var letterSpacingEm: CGFloat { token.letterSpacingEm }

    /// The height of a line as a multiple of the size.
    var lineHeight: CGFloat { token.lineHeight }

    var isUppercase: Bool { token.isUppercase }

    /// The system style whose Dynamic Type scaling this style follows.
    var scalesLike: Font.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title2
        case .headline: .headline
        case .body: .body
        case .callout: .callout
        case .subheadline: .subheadline
        case .footnote: .footnote
        // Not caption2, which stops shrinking at 11 points: the accessibility
        // audit reports text that keeps its size as partly unsupported (W2793).
        case .label: .caption
        case .code: .caption
        }
    }

    var font: Font {
        Font.custom(family, size: size, relativeTo: scalesLike).weight(weight)
    }

    /// The style at a text size: its scaled size, letter spacing and the space
    /// to add between lines to reach its line height.
    func metrics(at textSize: UIContentSizeCategory) -> StrideTextMetrics {
        let traits = UITraitCollection(preferredContentSizeCategory: textSize)
        let pointSize = UIFontMetrics(forTextStyle: uiTextStyle).scaledValue(for: size, compatibleWith: traits)
        let descriptor = UIFontDescriptor(fontAttributes: [
            .family: family,
            .traits: [UIFontDescriptor.TraitKey.weight: uiWeight],
        ])
        let uiFont = UIFont(descriptor: descriptor, size: pointSize)

        return StrideTextMetrics(
            pointSize: pointSize,
            familyName: uiFont.familyName,
            tracking: pointSize * letterSpacingEm,
            lineSpacing: max(0, pointSize * lineHeight - uiFont.lineHeight)
        )
    }

    private var uiTextStyle: UIFont.TextStyle {
        switch scalesLike {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }

    private var uiWeight: UIFont.Weight {
        switch weight {
        case .bold: .bold
        case .semibold: .semibold
        case .medium: .medium
        default: .regular
        }
    }
}

extension View {
    /// Shows the view's text in a Stride text style.
    func textStyle(_ style: StrideTextStyle) -> some View {
        modifier(StrideTextStyleModifier(style: style))
    }
}
