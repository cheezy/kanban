import SwiftUI
import Testing
import UIKit

/// A view drawn into a bitmap, from a window of the app that hosts the tests.
@MainActor
struct Drawing {
    let pixels: [UInt8]
    private let width: Int
    private let height: Int

    init(
        of view: some View,
        in style: UIUserInterfaceStyle = .light,
        textSize: UIContentSizeCategory = .large,
        width: Int = 390,
        height: Int = 844
    ) throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.overrideUserInterfaceStyle = style
        window.traitOverrides.preferredContentSizeCategory = textSize
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()

        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        try #require(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))

        let bitmap = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        pixels = Array(UnsafeBufferPointer(start: bitmap, count: width * height * 4))
        self.width = width
        self.height = height
    }

    /// The red, green and blue of the top left corner, where no view draws.
    var corner: [UInt8] { pixel(x: 0, y: 0) }

    /// The darkest and lightest green.
    var darkest: UInt8 { greens.min() ?? 255 }
    var lightest: UInt8 { greens.max() ?? 0 }

    /// How many rows hold a pixel that differs from the corner.
    var drawnRows: Int {
        (0..<height).count(where: rowIsDrawn)
    }

    /// The last row that holds such a pixel, or -1 when none does.
    var lastDrawnRow: Int {
        (0..<height).last(where: rowIsDrawn) ?? -1
    }

    /// The width from the first to the last column that holds such a pixel.
    var drawnWidth: Int {
        let columns = (0..<width).filter { column in
            (0..<height).contains { isDrawn(x: column, y: $0) }
        }
        guard let first = columns.first, let last = columns.last else { return 0 }

        return last - first + 1
    }

    /// How many bands of rows inside a filled shape, such as a verdict tile,
    /// hold its ink, one band per line of text or icon set one above another.
    /// The shape is the run of rows whose pixel at `x` matches the one at
    /// (`x`, `y`), a point on its fill left of its content; a row holds ink
    /// when a pixel right of `x + 8` differs from the fill.
    func inkBands(x: Int, y: Int) -> Int {
        let fill = pixel(x: x, y: y)
        let isFill = { (column: Int, row: Int) in
            zip(pixel(x: column, y: row), fill).allSatisfy { abs(Int($0) - Int($1)) <= 24 }
        }
        let top = (0...y).reversed().first { !isFill(x, $0) }.map { $0 + 1 } ?? 0
        let bottom = (y..<height).first { !isFill(x, $0) } ?? height
        let inked = (top..<bottom).map { row in
            (x + 8..<width - x).contains { !isFill($0, row) }
        }

        return zip([false] + inked, inked).count { !$0 && $1 }
    }

    private var greens: [UInt8] {
        stride(from: 1, to: pixels.count, by: 4).map { pixels[$0] }
    }

    private func rowIsDrawn(_ row: Int) -> Bool {
        (0..<width).contains { isDrawn(x: $0, y: row) }
    }

    /// Whether the pixel's red, green or blue differs from the corner's,
    /// compared in place so a tall drawing scans quickly.
    private func isDrawn(x: Int, y: Int) -> Bool {
        let start = (y * width + x) * 4

        return pixels[start] != pixels[0] || pixels[start + 1] != pixels[1] || pixels[start + 2] != pixels[2]
    }

    private func pixel(x: Int, y: Int) -> [UInt8] {
        let start = (y * width + x) * 4

        return Array(pixels[start..<start + 3])
    }
}
