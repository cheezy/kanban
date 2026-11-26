import StrideKit
import SwiftUI
import Testing

@testable import Stride

/// The suite CI runs on both devices for image tests.
@MainActor
@Suite(.serialized)
struct SnapshotTests {
    private static let storeURL = URL(string: "https://apps.apple.com/app/stride")!

    @Test("the root view follows the light and dark appearance")
    func rootViewFollowsAppearance() throws {
        let view = RootView(update: AppUpdateState())
        let light = try Drawing(of: view, in: .light)
        let dark = try Drawing(of: view, in: .dark)

        #expect(light.darkest > 200)
        #expect(dark.lightest < 60)
    }

    @Test("the root view shows the update screen when an update is required")
    func rootViewShowsUpdateScreen() throws {
        let required = try Drawing(of: RootView(update: AppUpdateState(storeURL: Self.storeURL)))
        let screen = try Drawing(of: UpdateRequiredView(storeURL: Self.storeURL))
        let accepted = try Drawing(of: RootView(update: AppUpdateState()))

        #expect(required.pixels == screen.pixels)
        #expect(required.drawnRows > 50)
        #expect(accepted.drawnRows == 0)
    }

    @Test("the update screen's text stands out in light and dark")
    func updateScreenAppearance() throws {
        let light = try Drawing(of: UpdateRequiredView(storeURL: Self.storeURL), in: .light)
        let dark = try Drawing(of: UpdateRequiredView(storeURL: Self.storeURL), in: .dark)

        #expect(light.corner == [255, 255, 255])
        #expect(light.darkest < 60)
        #expect(dark.corner == [0, 0, 0])
        #expect(dark.lightest > 200)
    }

    @Test("the update screen grows with the text size")
    func updateScreenTextSize() throws {
        let view = UpdateRequiredView(storeURL: Self.storeURL)
        let normal = try Drawing(of: view)
        let largest = try Drawing(of: view, textSize: .accessibilityExtraExtraExtraLarge)

        #expect(largest.drawnRows > normal.drawnRows * 2)
    }

    @Test("the update screen keeps a readable width on an iPad, and a wider one for large text")
    func updateScreenWidth() throws {
        let view = UpdateRequiredView(storeURL: Self.storeURL)
        let normal = try Drawing(of: view, width: 820, height: 1180)
        let largest = try Drawing(
            of: view, textSize: .accessibilityExtraExtraExtraLarge, width: 820, height: 1180
        )

        // The text and the link, without the 16 points of padding at each side.
        #expect((200...368).contains(normal.drawnWidth))
        #expect(largest.drawnWidth == 608)
    }
}
