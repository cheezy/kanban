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

    /// A device signed in while the server has not said whether its plan
    /// includes the app, so the root view shows only the background. Unlike
    /// `.starting`, the phase stays put with no store to read.
    private static func checking() -> SignInModel {
        SignInModel(services: nil, unlock: .faceID, phase: .signedIn(.checking))
    }

    private static func root(_ update: AppUpdateState, _ signIn: SignInModel) -> RootView {
        RootView(update: update, signIn: signIn, router: AppRouter(api: nil))
    }

    private static func signInScreen(_ phase: SignInPhase = .signedOut(nil)) -> SignInView {
        SignInView(model: SignInModel(services: nil, unlock: .faceID, phase: phase))
    }

    @Test("the root view follows the light and dark appearance")
    func rootViewFollowsAppearance() throws {
        let view = Self.root(AppUpdateState(), Self.checking())
        let light = try Drawing(of: view, in: .light)
        let dark = try Drawing(of: view, in: .dark)

        #expect(light.darkest > 200)
        #expect(dark.lightest < 60)
    }

    /// Pins which way up `Drawing` draws. Without its flip the rows ran from
    /// the bottom of the window up, and a test that read the first drawn row
    /// as the top line still passed when the bottom line behaved the same
    /// (W2797).
    @Test("Drawing's rows run from the top of the window down")
    func drawingRunsTopDown() throws {
        let band = VStack(spacing: 0) {
            Color.white.frame(height: 10)
            Color.black.frame(height: 20)
            Color.white
        }
        .ignoresSafeArea()
        let drawing = try Drawing(of: band, width: 100, height: 200)

        #expect((9...11).contains(drawing.firstDrawnRow))
        #expect((28...30).contains(drawing.lastDrawnRow))
    }

    @Test("the root view shows the update screen when an update is required")
    func rootViewShowsUpdateScreen() throws {
        let required = try Drawing(of: Self.root(AppUpdateState(storeURL: Self.storeURL), Self.signedIn()))
        let screen = try Drawing(of: UpdateRequiredView(storeURL: Self.storeURL))
        let accepted = try Drawing(of: Self.root(AppUpdateState(), Self.checking()))

        #expect(required.pixels == screen.pixels)
        #expect(required.drawnRows > 50)
        #expect(accepted.drawnRows == 0)
    }

    @Test("once signed in, the root view shows the shell in light and dark")
    func rootViewShowsShell() throws {
        let view = Self.root(AppUpdateState(), Self.signedIn())
        let light = try Drawing(of: view, in: .light)
        let dark = try Drawing(of: view, in: .dark)
        let waiting = try Drawing(of: Self.root(AppUpdateState(), Self.checking()), in: .light)

        #expect(light.drawnRows > 50)
        #expect(light.pixels != waiting.pixels)
        #expect(light.darkest < 80)
        #expect(dark.lightest > 180)
        #expect(light.corner.allSatisfy { $0 > 200 })
        #expect(dark.corner.allSatisfy { $0 < 60 })
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
        let root = try Drawing(of: Self.root(AppUpdateState(), signedOut))
        let screen = try Drawing(of: Self.signInScreen())

        #expect(root.pixels == screen.pixels)
        #expect(root.drawnRows > 300)
    }

    @Test("the root view shows the update screen before the Sign in screen")
    func rootViewPutsUpdateFirst() throws {
        let signedOut = SignInModel(services: nil, unlock: .faceID, phase: .signedOut(nil))
        let root = try Drawing(of: Self.root(AppUpdateState(storeURL: Self.storeURL), signedOut))
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

    /// A review screen's tile or file row in a phone's column, at the top
    /// left of the drawing.
    private static func reviewPart(_ view: some View, textSize: UIContentSizeCategory) throws -> Drawing {
        let column = view
            .padding(16)
            .frame(width: 390)
            .frame(maxHeight: .infinity, alignment: .top)
            // From the bitmap's top row, so a point such as (20, 30) is on
            // the part on every device, whatever its status bar's height.
            .ignoresSafeArea()

        return try Drawing(of: column, textSize: textSize, width: 390, height: 1600)
    }

    @Test("a verdict tile puts its name under its mark at the accessibility sizes")
    func verdictTileStacks() throws {
        let tile = ReviewVerdictTile(
            tile: ReviewTile(verdict: Verdict(section: .patterns, state: .failed), note: nil, criteria: nil)
        )
        let normal = try Self.reviewPart(tile, textSize: .large)
        let largest = try Self.reviewPart(tile, textSize: .accessibilityExtraExtraExtraLarge)

        // A point on the fill in the tile's left padding. Beside each other,
        // the cross and the name make one band of ink; at the largest text,
        // where a name beside them broke mid-word, they make two.
        #expect(normal.inkBands(x: 20, y: 30) == 1)
        #expect(largest.inkBands(x: 20, y: 40) == 2)
    }

    @Test("a file row gives a long path its own line at the accessibility sizes")
    func fileRowStacks() throws {
        let path = "mobile/ios/StrideTests/SignInViewModelTests.swift"
        let json = #"{"index": 0, "path": "\#(path)", "additions": 120, "deletions": 4, "truncated": false, "flagged": true}"#
        let file = try JSONDecoder().decode(Components.Schemas.ReviewFile.self, from: Data(json.utf8))
        let row = ReviewFileRowView(file: ReviewFileRow(file))
        let alone = Text(verbatim: path)
            .textStyle(.code)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        let largest = try Self.reviewPart(row, textSize: .accessibilityExtraExtraExtraLarge)
        let pathAlone = try Self.reviewPart(alone, textSize: .accessibilityExtraExtraExtraLarge)

        // With the flag above and the counts below, the row draws under
        // twice the path's rows of ink (237 to 132 on iOS 27); squeezed
        // between them, the path broke every few characters and the row
        // drew over three times as many (454).
        #expect(
            largest.drawnRows * 2 < pathAlone.drawnRows * 5,
            "row \(largest.drawnRows), path \(pathAlone.drawnRows)"
        )
    }

    // MARK: Now

    @Test("a View attempt row puts its value under its name at the accessibility sizes")
    func attemptRowStacks() throws {
        let row = HookAttemptRow(name: .nowAttemptExitCode, value: "1")
            .padding(16)
            .frame(width: 600)
            .frame(maxHeight: .infinity, alignment: .top)
        let normal = try Drawing(of: row, width: 600, height: 1200)
        let largest = try Drawing(of: row, textSize: .accessibilityExtraExtraExtraLarge, width: 600, height: 1200)

        // Side by side, the name and the value span the row less its padding;
        // stacked, the row is only as wide as its name.
        #expect(normal.drawnWidth > 500, "drawn width \(normal.drawnWidth)")
        #expect(largest.drawnWidth < 400, "drawn width \(largest.drawnWidth)")
    }

    @Test("offline, the Ready card says it needs a connection, as the other cards' buttons do")
    func readyCardOffline() async throws {
        let cards = try await DecisionFixtures.cards()
        let ready = try #require(cards.first { $0.kind == .readyEmpty })
        let online = try Self.reviewPart(ReadyEmptyCardView(card: ready, open: {}, isOffline: false), textSize: .large)
        let offline = try Self.reviewPart(ReadyEmptyCardView(card: ready, open: {}, isOffline: true), textSize: .large)

        // The footnote's line adds about 20 rows; a disabled row alone adds one.
        #expect(offline.drawnRows > online.drawnRows + 10, "offline \(offline.drawnRows), online \(online.drawnRows)")
    }

    @Test("the reply sheet's Cancel waits while the reply is on its way")
    func replyCancelWaitsWhileSending() async throws {
        let comment = Operations.CommentOnMyTask.id
        let gate = DispatchSemaphore(value: 0)
        let api = FixtureAPI(answering: { operation in
            if operation == comment { gate.wait() }
            return nil
        }).client
        let reply = ReplyModel(
            cardID: "released-9001", taskID: 9001, identifier: "W100", title: "Drop the old column",
            api: api, isOffline: { false }
        )
        reply.text = "Done."
        let idle = try Drawing(of: ReplySheet(reply: reply, send: {}))

        let sending = Task { await reply.send() }
        do {
            defer { gate.signal() }
            await waitUntil { reply.isSending }
            let waiting = try Drawing(of: ReplySheet(reply: reply, send: {}))

            // Cancel is the sheet's top line, so it starts at the first drawn
            // row. Disabled, its ink is lighter.
            try #require(idle.firstDrawnRow >= 0)
            let cancel = idle.firstDrawnRow..<idle.firstDrawnRow + 17
            #expect(
                Int(waiting.darkest(in: cancel)) > Int(idle.darkest(in: cancel)) + 40,
                "Cancel darkest \(idle.darkest(in: cancel)) idle, \(waiting.darkest(in: cancel)) sending"
            )
        }
        _ = await sending.value
    }
}
