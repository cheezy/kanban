import Foundation
import Testing

@testable import StrideKit

struct InstallMarkerTests {
    private let container: TemporaryDirectory

    init() throws {
        container = try TemporaryDirectory()
    }

    @Test("exists once it is created, and holds nothing")
    func create() throws {
        let marker = InstallMarker(container: container.url)
        #expect(marker.exists == false)

        try marker.create()

        #expect(marker.exists)
        #expect(InstallMarker(container: container.url).exists)
        #expect(try Data(contentsOf: marker.url).isEmpty)
    }

    @Test("is gone with its container")
    func goneWithContainer() throws {
        let marker = InstallMarker(container: container.url)
        try marker.create()

        try FileManager.default.removeItem(at: container.url)

        #expect(marker.exists == false)
    }

    @Test("throws when the container is missing")
    func missingContainer() {
        let marker = InstallMarker(container: container.url.appending(path: "missing"))

        #expect(throws: CocoaError.self) { try marker.create() }
    }
}
