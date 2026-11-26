import StrideKit
import SwiftUI
import Testing

@testable import Stride

/// The suite CI runs on both devices for image tests.
@MainActor
@Suite(.serialized)
struct SnapshotTests {
    private static let storeURL = URL(string: "https://apps.apple.com/app/stride")!

    /// A device that is signed in and whose plan includes the app, so the root
    /// view shows what lies past the Sign in screen.
    private static func signedIn() -> SignInModel {
        SignInModel(services: nil, unlock: .faceID, phase: .signedIn(.unlocked))
    }

    private static func signInScreen(_ phase: SignInPhase = .signedOut(nil)) -> SignInView {
        SignInView(model: SignInModel(services: nil, unlock: .faceID, phase: phase))
    }

    @Test("the root view follows the light and dark appearance")
    func rootViewFollowsAppearance() throws {
        let view = RootView(update: AppUpdateState(), signIn: Self.signedIn())
        let light = try Drawing(of: view, in: .light)
        let dark = try Drawing(of: view, in: .dark)

        #expect(light.darkest > 200)
        #expect(dark.lightest < 60)
    }

    @Test("the root view shows the update screen when an update is required")
    func rootViewShowsUpdateScreen() throws {
        let required = try Drawing(of: RootView(update: AppUpdateState(storeURL: Self.storeURL), signIn: Self.signedIn()))
        let screen = try Drawing(of: UpdateRequiredView(storeURL: Self.storeURL))
        let accepted = try Drawing(of: RootView(update: AppUpdateState(), signIn: Self.signedIn()))

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

    @Test("the root view shows the Sign in screen until the device is signed in")
    func rootViewShowsSignIn() throws {
        let signedOut = SignInModel(services: nil, unlock: .faceID, phase: .signedOut(nil))
        let root = try Drawing(of: RootView(update: AppUpdateState(), signIn: signedOut))
        let screen = try Drawing(of: Self.signInScreen())

        #expect(root.pixels == screen.pixels)
        #expect(root.drawnRows > 300)
    }

    @Test("the root view shows the update screen before the Sign in screen")
    func rootViewPutsUpdateFirst() throws {
        let signedOut = SignInModel(services: nil, unlock: .faceID, phase: .signedOut(nil))
        let root = try Drawing(of: RootView(update: AppUpdateState(storeURL: Self.storeURL), signIn: signedOut))
        let screen = try Drawing(of: UpdateRequiredView(storeURL: Self.storeURL))

        #expect(root.pixels == screen.pixels)
    }

    @Test("the Sign in screen's text stands out in light and dark")
    func signInAppearance() throws {
        let light = try Drawing(of: Self.signInScreen(), in: .light)
        let dark = try Drawing(of: Self.signInScreen(), in: .dark)

        #expect(light.corner == [255, 255, 255])
        #expect(light.darkest < 60)
        #expect(dark.corner == [0, 0, 0])
        #expect(dark.lightest > 200)
    }

    @Test("the locked panel takes the place of the Sign in button")
    func lockedPanelReplacesButton() throws {
        let signedOut = try Drawing(of: Self.signInScreen())
        let locked = try Drawing(of: Self.signInScreen(.locked))
        let failed = try Drawing(of: Self.signInScreen(.signedOut(.network)))

        #expect(locked.pixels != signedOut.pixels)
        #expect(failed.pixels != signedOut.pixels)
    }

    @Test("the Sign in screen scrolls at the largest text size")
    func signInTextSize() throws {
        let normal = try Drawing(of: Self.signInScreen())
        let largest = try Drawing(of: Self.signInScreen(), textSize: .accessibilityExtraExtraExtraLarge)

        #expect(largest.drawnRows > normal.drawnRows)
    }

    @Test("the Sign in screen keeps a readable width on an iPad, and a wider one for large text")
    func signInWidth() throws {
        let normal = try Drawing(of: Self.signInScreen(), width: 1180, height: 820)
        let largest = try Drawing(
            of: Self.signInScreen(), textSize: .accessibilityExtraExtraExtraLarge, width: 1180, height: 820
        )

        // The column is 480 or 640 points wide, less 28 points of padding at each
        // side; the button's smoothed edges reach one point further on each.
        #expect(normal.drawnWidth >= 300)
        #expect(normal.drawnWidth <= 426, "drawn width \(normal.drawnWidth)")
        #expect(largest.drawnWidth > normal.drawnWidth)
        #expect(largest.drawnWidth <= 586, "drawn width \(largest.drawnWidth)")
    }
}
