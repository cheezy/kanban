import UIKit

/// The app's colour assets resolved in a theme, and the WCAG 2 contrast of two
/// of them.
enum Contrast {
    /// The asset named `name` in "light" or "dark".
    static func color(_ name: String, in theme: String) -> UIColor? {
        let traits = UITraitCollection(userInterfaceStyle: theme == "dark" ? .dark : .light)
        return UIColor(named: name, in: .main, compatibleWith: traits)?.resolvedColor(with: traits)
    }

    static func components(of color: UIColor) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red, green, blue, alpha)
    }

    /// The WCAG 2 contrast ratio of two opaque colours.
    static func ratio(_ foreground: UIColor, on background: UIColor) -> Double {
        let lighter = max(luminance(foreground), luminance(background))
        let darker = min(luminance(foreground), luminance(background))
        return (lighter + 0.05) / (darker + 0.05)
    }

    static func luminance(_ color: UIColor) -> Double {
        let parts = components(of: color)
        let linear = { (value: CGFloat) -> Double in
            let channel = Double(value)
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(parts.red) + 0.7152 * linear(parts.green) + 0.0722 * linear(parts.blue)
    }
}
