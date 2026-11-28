import Foundation

/// A file's added and removed lines as the diff header and the review's file
/// rows show them, "+3" and "−2", in the locale's digits.
enum LineCountText {
    /// "+3": the count with its sign.
    static func added(_ count: Int, in locale: Locale) -> String {
        count.formatted(.number.sign(strategy: .always()).locale(locale))
    }

    /// "−2", with the design's minus sign (U+2212), which a number style
    /// cannot give.
    static func removed(_ count: Int, in locale: Locale) -> String {
        "\u{2212}" + count.formatted(.number.locale(locale))
    }
}
