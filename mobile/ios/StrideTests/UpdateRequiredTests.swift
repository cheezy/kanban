import Foundation
import StrideKit
import Testing

@testable import Stride

@MainActor
struct UpdateRequiredTests {
    @Test("the app starts accepted")
    func startsAccepted() {
        #expect(AppUpdateState.atLaunch(arguments: ["Stride"]).storeURL == nil)
    }

    @Test("a debug build can start on the update screen")
    func startsRefused() {
        let update = AppUpdateState.atLaunch(arguments: ["Stride", "-StrideUpdateRequired"])

        #expect(update.storeURL == URL(string: "https://apps.apple.com/app/stride"))
    }

    @Test("the app reports the version and build it was built with")
    func version() throws {
        let version = try #require(BuiltBundle.app.infoString("CFBundleShortVersionString"))
        let build = try #require(BuiltBundle.app.infoString("CFBundleVersion"))

        #expect(AppVersion(bundle: .main) != nil)
        #expect(AppVersion(bundle: .main) == AppVersion(version: version, build: build))
    }

    @Test("the app has a client")
    func client() {
        #expect(StrideApp.api != nil)
    }
}
