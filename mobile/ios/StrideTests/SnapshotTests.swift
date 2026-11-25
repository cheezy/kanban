import SwiftUI
import Testing

@testable import Stride

/// The suite CI runs on both devices for image tests.
@MainActor
struct SnapshotTests {
    @Test("the root view follows the light and dark appearance")
    func rootViewFollowsAppearance() throws {
        let light = try pixel(of: RootView(), in: .light)
        let dark = try pixel(of: RootView(), in: .dark)

        #expect(light.min() ?? 0 > 200)
        #expect(dark.max() ?? 255 < 60)
    }

    /// The red, green and blue of the view's centre. The view is drawn straight
    /// into a bitmap, because `ImageRenderer.cgImage` can come back blank while a
    /// simulator is still starting.
    private func pixel(of view: some View, in colorScheme: ColorScheme) throws -> [UInt8] {
        let renderer = ImageRenderer(
            content: view.frame(width: 4, height: 4).environment(\.colorScheme, colorScheme)
        )
        let context = try #require(
            CGContext(
                data: nil,
                width: 4,
                height: 4,
                bitsPerComponent: 8,
                bytesPerRow: 16,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        renderer.render { _, draw in draw(context) }

        let bitmap = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let centre = 2 * 16 + 2 * 4
        #expect(bitmap[centre + 3] == 255, "the view is not opaque")
        return (centre..<centre + 3).map { bitmap[$0] }
    }
}
