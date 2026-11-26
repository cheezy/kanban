import SwiftUI
import Testing
import UIKit

@testable import Stride

/// The app's colours and type against `mobile/shared/tokens/tokens.json`, which
/// `mix mobile.tokens` writes from the web's `.stride-screen` tokens. A token in
/// `tokens.json` with no colour asset, or an asset or Swift token whose value
/// differs, fails here. A token changed in `app.css` and not regenerated fails
/// the ExUnit staleness tests in `test/kanban/mobile/` instead.
struct DesignTokenTests {
    @Test("every colour token has an asset with its light and its dark value", arguments: ["light", "dark"])
    func everyTokenHasAnAsset(theme: String) throws {
        let colors = try Self.tokens(theme)["color"] as? [String: [String: String]]
        let tokens = try #require(colors)

        #expect(tokens.count > 50)
        for (name, token) in tokens {
            let hex = try #require(token["hex"])
            let asset = try #require(Self.color(name, in: theme), "\(name) has no colour asset")

            #expect(Self.hex(of: asset) == hex, "\(name) is \(Self.hex(of: asset)) in \(theme), not \(hex)")
        }
    }

    @Test("names each colour through the symbol Xcode makes of it")
    func generatedSymbols() throws {
        let pairs: [(ColorResource, String)] = [(.ink, "ink"), (.ink2, "ink-2"), (.stBlockedSoft, "st-blocked-soft"), (.lineInput, "line-input")]
        let tokens = try #require(Self.tokens("light")["color"] as? [String: [String: String]])
        let light = UITraitCollection(userInterfaceStyle: .light)

        for (resource, name) in pairs {
            let color = UIColor(resource: resource).resolvedColor(with: light)

            #expect(Self.hex(of: color) == tokens[name]?["hex"], "\(name)")
        }
    }

    @Test(
        "text colours reach 4.5:1 on their backgrounds, and borders and accents their own floors",
        arguments: ["light", "dark"]
    )
    func contrast(theme: String) throws {
        for pair in Self.contrastPairs {
            let foreground = try #require(Self.color(pair.foreground, in: theme), "\(pair.foreground) is missing")
            let background = try #require(Self.color(pair.background, in: theme), "\(pair.background) is missing")
            let ratio = Self.contrast(foreground, on: background)

            #expect(
                ratio >= pair.floor,
                "\(pair.foreground) on \(pair.background) is \(ratio):1 in \(theme), under \(pair.floor):1"
            )
        }
    }

    @Test("type styles scale with Dynamic Type", arguments: StrideTextStyle.allCases)
    func typeScales(style: StrideTextStyle) {
        let small = style.metrics(at: .extraSmall)
        let standard = style.metrics(at: .large)
        let larger = style.metrics(at: .extraExtraExtraLarge)
        let largest = style.metrics(at: .accessibilityExtraExtraExtraLarge)

        #expect(standard.pointSize == style.size)
        // The smallest styles stop shrinking at 11 points, as the system's do.
        #expect(small.pointSize <= standard.pointSize)
        #expect(larger.pointSize > standard.pointSize)
        #expect(largest.pointSize > standard.pointSize * 1.5)
        #expect(largest.lineSpacing >= 0)
    }

    @MainActor
    @Test("text in a style is drawn larger at a larger text size", arguments: StrideTextStyle.allCases)
    func drawnTextScales(style: StrideTextStyle) throws {
        let text = Text(verbatim: "Stride").textStyle(style).fixedSize()
        let standard = try Drawing(of: text, textSize: .large, width: 600, height: 300)
        let largest = try Drawing(of: text, textSize: .accessibilityExtraExtraExtraLarge, width: 600, height: 300)

        #expect(standard.drawnRows > 0)
        #expect(largest.drawnRows > standard.drawnRows)
    }

    @Test("type styles draw in the bundled token families", arguments: StrideTextStyle.allCases)
    func typeFamilies(style: StrideTextStyle) {
        #expect(style.metrics(at: .large).familyName == style.family)
        #expect([DesignTokens.sansFamily, DesignTokens.monoFamily].contains(style.family))
    }

    /// `Font.custom` draws in a system font when it cannot find the family, so
    /// the font `.textStyle` applies must draw differently from the same call
    /// made with a family that does not exist.
    @MainActor
    @Test("text in a style is drawn in its family, not the system font", arguments: StrideTextStyle.allCases)
    func drawnInFamily(style: StrideTextStyle) throws {
        let sample = "Stride W2787 Rg"
        let styled = Text(verbatim: sample).font(style.font).fixedSize()
        let missing = Font.custom("No Such Family", size: style.size, relativeTo: style.scalesLike).weight(style.weight)
        let system = Text(verbatim: sample).font(missing).fixedSize()

        let drawn = try Drawing(of: styled, width: 600, height: 120)
        let fallback = try Drawing(of: system, width: 600, height: 120)

        #expect(drawn.drawnRows > 0)
        #expect(drawn.pixels != fallback.pixels)
    }

    @Test("every text style token has a style, and each style is its token")
    func textStyleTokens() throws {
        let tokens = try #require(Self.tokens("light")["text_style"] as? [String: [String: Any]])
        let names: [StrideTextStyle: String] = [
            .largeTitle: "large-title", .title: "title", .headline: "headline", .body: "body",
            .callout: "callout", .subheadline: "subheadline", .footnote: "footnote", .label: "label", .code: "code",
        ]
        let families = ["font-sans": DesignTokens.sansFamily, "font-mono": DesignTokens.monoFamily]
        let weights: [Int: Font.Weight] = [400: .regular, 500: .medium, 600: .semibold, 700: .bold]

        #expect(Set(names.values) == Set(tokens.keys))
        #expect(names.count == StrideTextStyle.allCases.count)
        for style in StrideTextStyle.allCases {
            let name = try #require(names[style])
            let token = try #require(tokens[name], "\(name) has no token")

            #expect(families[token["family"] as? String ?? ""] == style.family, "\(name)")
            #expect((token["size_pt"] as? Double).map { CGFloat($0) } == style.size, "\(name)")
            #expect(weights[token["weight"] as? Int ?? 0] == style.weight, "\(name)")
            #expect((token["letter_spacing_em"] as? Double).map { CGFloat($0) } == style.letterSpacingEm, "\(name)")
            #expect((token["line_height"] as? Double).map { CGFloat($0) } == style.lineHeight, "\(name)")
            #expect(token["uppercase"] as? Bool == style.isUppercase, "\(name)")
        }
    }

    @Test("the Swift tokens match tokens.json")
    func swiftTokens() throws {
        let light = try Self.tokens("light")
        let fonts = try #require(light["font"] as? [String: String])
        let radii = try #require(light["radius"] as? [String: Double])

        #expect(Self.firstFamily(of: fonts["font-sans"]) == DesignTokens.sansFamily)
        #expect(Self.firstFamily(of: fonts["font-mono"]) == DesignTokens.monoFamily)
        let swiftRadii = [
            "r-sm": DesignTokens.Radius.sm, "r-md": DesignTokens.Radius.md,
            "r-lg": DesignTokens.Radius.lg, "r-xl": DesignTokens.Radius.xl,
        ]
        #expect(radii == swiftRadii.mapValues(Double.init))
    }

    // MARK: Support

    struct Pair {
        let foreground: String
        let background: String
        let floor: Double
    }

    /// The pairs `mix dark_mode.contrast` holds the web to, in
    /// `docs/dark-mode-contract.md`, for the tokens the app has.
    static let contrastPairs: [Pair] = {
        let surfaces = ["bg", "surface", "surface-2", "surface-sunken"]
        let statuses = ["backlog", "ready", "doing", "review", "done", "blocked"]
        let labels = ["red", "orange", "yellow", "green", "teal", "blue", "purple", "pink", "gray"]
        var pairs: [Pair] = []

        for background in surfaces {
            pairs += ["ink", "ink-2", "ink-3"].map { Pair(foreground: $0, background: background, floor: 4.5) }
            pairs.append(Pair(foreground: "ink-4", background: background, floor: 3))
            pairs += ["line", "line-2", "line-strong"].map { Pair(foreground: $0, background: background, floor: 1.5) }
            // A form control's border is its only edge.
            pairs.append(Pair(foreground: "line-input", background: background, floor: 3))
        }
        for status in statuses {
            pairs.append(Pair(foreground: "st-\(status)", background: "st-\(status)-soft", floor: 4.5))
            pairs.append(Pair(foreground: "line", background: "st-\(status)-soft", floor: 1.5))
        }
        for label in labels {
            pairs.append(Pair(foreground: "label-\(label)", background: "label-\(label)-soft", floor: 4.5))
            pairs.append(Pair(foreground: "line", background: "label-\(label)-soft", floor: 1.5))
        }
        for brand in ["orange", "violet"] {
            pairs.append(Pair(foreground: "stride-\(brand)-ink", background: "stride-\(brand)-soft", floor: 4.5))
            pairs.append(Pair(foreground: "stride-\(brand)", background: "bg", floor: 3))
        }
        for foreground in ["hitme-white", "hitme-lead", "hitme-caption", "hitme-cyan", "hitme-yellow"] {
            pairs.append(Pair(foreground: foreground, background: "hitme-navy", floor: 4.5))
        }
        pairs.append(Pair(foreground: "hitme-on-cyan", background: "hitme-cyan", floor: 4.5))
        pairs.append(Pair(foreground: "hitme-navy", background: "hitme-white", floor: 4.5))
        return pairs
    }()

    private static func tokens(_ theme: String) throws -> [String: Any] {
        let url = try #require(
            Bundle(for: Anchor.self).url(forResource: "tokens", withExtension: "json", subdirectory: "tokens")
        )
        let file = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let themes = try #require(file?["themes"] as? [String: Any])
        return try #require(themes[theme] as? [String: Any])
    }

    private static func color(_ name: String, in theme: String) -> UIColor? {
        let traits = UITraitCollection(userInterfaceStyle: theme == "dark" ? .dark : .light)
        return UIColor(named: name, in: .main, compatibleWith: traits)?.resolvedColor(with: traits)
    }

    private static func components(of color: UIColor) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red, green, blue, alpha)
    }

    /// `#rrggbb`, with `aa` after it when the colour is not opaque, as the
    /// tokens write it.
    private static func hex(of color: UIColor) -> String {
        let parts = components(of: color)
        let byte = { (value: CGFloat) in String(format: "%02x", Int((value * 255).rounded())) }
        let rgb = "#" + byte(parts.red) + byte(parts.green) + byte(parts.blue)
        return parts.alpha < 1 ? rgb + byte(parts.alpha) : rgb
    }

    /// The WCAG 2 contrast ratio of two opaque colours.
    private static func contrast(_ foreground: UIColor, on background: UIColor) -> Double {
        let lighter = max(luminance(foreground), luminance(background))
        let darker = min(luminance(foreground), luminance(background))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func luminance(_ color: UIColor) -> Double {
        let parts = components(of: color)
        let linear = { (value: CGFloat) -> Double in
            let channel = Double(value)
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(parts.red) + 0.7152 * linear(parts.green) + 0.0722 * linear(parts.blue)
    }

    private static func firstFamily(of stack: String?) -> String? {
        stack?.split(separator: ",").first?.trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
    }

    private final class Anchor {}
}
