import Foundation
import Testing

@testable import StrideKit

struct AppGroupTests {
    private static let names = [
        AppGroup.identifierKey: "group.example",
        AppGroup.keychainAccessGroupKey: "TEAM.example.shared"
    ]

    @Test("reads both groups from the info dictionary")
    func readsBothGroups() throws {
        let group = try #require(AppGroup(infoDictionary: Self.names))

        #expect(group.identifier == "group.example")
        #expect(group.keychainAccessGroup == "TEAM.example.shared")
    }

    @Test(
        "is nil when a group is missing",
        arguments: [AppGroup.identifierKey, AppGroup.keychainAccessGroupKey]
    )
    func missingGroup(key: String) {
        var names = Self.names
        names[key] = nil

        #expect(AppGroup(infoDictionary: names) == nil)
    }

    @Test(
        "is nil when a group is empty",
        arguments: [AppGroup.identifierKey, AppGroup.keychainAccessGroupKey]
    )
    func emptyGroup(key: String) {
        var names = Self.names
        names[key] = ""

        #expect(AppGroup(infoDictionary: names) == nil)
    }

    @Test(
        "is nil when a group is not a string",
        arguments: [AppGroup.identifierKey, AppGroup.keychainAccessGroupKey]
    )
    func wrongType(key: String) {
        var names: [String: Any] = Self.names
        names[key] = ["group.example"]

        #expect(AppGroup(infoDictionary: names) == nil)
    }

    @Test("is nil for a bundle that names no groups")
    func bundleWithoutGroups() {
        #expect(AppGroup(bundle: Bundle(for: JSONEncoder.self)) == nil)
    }

    @Test("resolves the container of its own identifier")
    func resolvesContainer() throws {
        let group = try #require(AppGroup(infoDictionary: Self.names))

        let url = group.containerURL { URL(filePath: "/containers/\($0)") }

        #expect(url == URL(filePath: "/containers/group.example"))
    }

    @Test("has no container when the target is not entitled to the group")
    func noContainer() throws {
        let group = try #require(AppGroup(infoDictionary: Self.names))

        #expect(group.containerURL { _ in nil } == nil)
    }
}
