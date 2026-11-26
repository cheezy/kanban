import SwiftUI
import Testing
import UIKit

@testable import Stride

/// The shared views drawn in both appearances and at the default and largest
/// text sizes. CI runs this suite on both the iPhone and the iPad, as it does
/// `SnapshotTests`.
@MainActor
@Suite(.serialized)
struct SharedViewSnapshotTests {
    private static let largest = UIContentSizeCategory.accessibilityExtraExtraExtraLarge
    private static let english = Locale(identifier: "en")
    private static let german = Locale(identifier: "de")

    /// The samples that hold text, and so grow with the text size. A progress
    /// bar is a fixed 8 points high.
    private static let withText = SharedViewSamples.allCases.filter { $0 != .progress }

    @Test("each shared view in light and dark at default and largest text", arguments: SharedViewSamples.allCases)
    func lightAndDark(sample: SharedViewSamples) throws {
        let light = try Self.drawing(sample, in: .light)
        let dark = try Self.drawing(sample, in: .dark)
        let lightLargest = try Self.drawing(sample, in: .light, textSize: Self.largest)
        let darkLargest = try Self.drawing(sample, in: .dark, textSize: Self.largest)

        for drawing in [light, lightLargest] {
            #expect(drawing.corner == [255, 255, 255])
            #expect(drawing.drawnRows > 0)
            #expect(drawing.drawnWidth <= Self.widthInMargins(390))
            #expect(drawing.lastDrawnRow < Self.height - 1, "\(sample) runs off the bottom")
        }
        for drawing in [dark, darkLargest] {
            #expect(drawing.corner == [0, 0, 0])
            #expect(drawing.drawnRows > 0)
            #expect(drawing.drawnWidth <= Self.widthInMargins(390))
            #expect(drawing.lastDrawnRow < Self.height - 1, "\(sample) runs off the bottom")
        }
        #expect(light.pixels != dark.pixels)

        if Self.withText.contains(sample) {
            #expect(light.darkest < 120, "\(sample) has no dark text in light mode")
            #expect(dark.lightest > 140, "\(sample) has no light text in dark mode")
            #expect(lightLargest.drawnRows > light.drawnRows, "\(sample) does not grow with the text size")
            #expect(darkLargest.drawnRows > dark.drawnRows, "\(sample) does not grow with the text size")
        }
    }

    @Test("a long German label wraps without clipping", arguments: [SharedViewSamples.decision, .verdicts, .offline, .diff])
    func germanWraps(sample: SharedViewSamples) throws {
        let narrow = try Self.drawing(sample, textSize: Self.largest, locale: Self.german, width: 320)
        let wide = try Self.drawing(sample, textSize: Self.largest, locale: Self.german, width: 900)
        let english = try Self.drawing(sample, textSize: Self.largest, locale: Self.english, width: 320)

        // Text that wrapped takes more rows in the narrow width, where text
        // cut short with an ellipsis would take the same.
        #expect(narrow.drawnRows > wide.drawnRows)
        #expect(narrow.drawnWidth <= Self.widthInMargins(320))
        #expect(narrow.lastDrawnRow < Self.height - 1, "\(sample) runs off the bottom")
        if sample != .diff {
            #expect(narrow.pixels != english.pixels)
        }
    }

    /// The window's height: tall enough for the samples at the largest text in
    /// a narrow width, and under the 8192-pixel limit at 3x, beyond which
    /// `drawHierarchy` draws nothing.
    private static let height = 2_700

    /// The width inside the 16-point margins, and the 5 points a card's shadow
    /// reaches past its edge on each side.
    private static func widthInMargins(_ width: Int) -> Int {
        width - 32 + 10
    }

    /// The sample with the screen's 16-point margins, from the top of a window
    /// tall enough for the largest text.
    private static func drawing(
        _ sample: SharedViewSamples,
        in style: UIUserInterfaceStyle = .light,
        textSize: UIContentSizeCategory = .large,
        locale: Locale = english,
        width: Int = 390
    ) throws -> Drawing {
        let view = sample.view
            .padding(16)
            .frame(width: CGFloat(width))
            .frame(maxHeight: .infinity, alignment: .top)
            .environment(\.locale, locale)

        return try Drawing(of: view, in: style, textSize: textSize, width: width, height: Self.height)
    }
}
