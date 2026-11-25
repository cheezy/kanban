import Foundation
import Testing

@testable import Stride

@MainActor
struct SmokeTests {
    @Test("StrideKit links into the app target")
    func strideKitLinks() throws {
        let group = try #require(StrideApp.appGroup)

        #expect(group.identifier == "group.com.stridelikeaboss.app")
    }

    @Test("the app group container is reachable")
    func appGroupContainer() throws {
        let group = try #require(StrideApp.appGroup)
        let container = try #require(group.containerURL(), "the app is not entitled to its app group")

        #expect(FileManager.default.fileExists(atPath: container.path(percentEncoded: false)))
    }

    @Test("a group the app is not entitled to has no container")
    func otherGroupContainer() {
        let other = "group.com.stridelikeaboss.other"

        #expect(FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: other) == nil)
    }
}
