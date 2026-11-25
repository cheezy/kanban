import Foundation
import Security
import Testing

@testable import Stride
@testable import StrideKit

/// Runs `AuthStore` on the simulator's own Keychain. A service of its own keeps it
/// away from the app's item, and each test removes what it stored.
@MainActor
struct AuthStoreKeychainTests {
    private let service = "AuthStoreKeychainTests-\(UUID().uuidString)"
    private let pair = TokenPair(
        accessToken: "EXAMPLE-access-1",
        accessTokenExpiresAt: Date(timeIntervalSince1970: 1_800_000_000),
        refreshToken: "EXAMPLE-refresh-1"
    )
    private let nextPair = TokenPair(
        accessToken: "EXAMPLE-access-2",
        accessTokenExpiresAt: Date(timeIntervalSince1970: 1_800_003_600),
        refreshToken: "EXAMPLE-refresh-2"
    )

    @Test("saves, rotates and clears the pair in the shared access group")
    func roundTrip() async throws {
        defer { cleanUp() }
        let group = try #require(StrideApp.appGroup)
        let store = try makeStore(accessGroup: group.keychainAccessGroup)

        try await store.save(pair)
        #expect(try await store.read() == pair)

        let item = try #require(storedAttributes())
        #expect(item[kSecAttrAccessGroup as String] as? String == group.keychainAccessGroup)
        #expect(
            item[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        #expect(item[kSecAttrSynchronizable as String] as? Bool != true)

        try await store.save(pair)
        try await store.rotate(from: pair, to: nextPair)
        #expect(try await store.read() == nextPair)

        try await store.clear()
        #expect(try await store.read() == nil)
        #expect(storedAttributes() == nil)

        try await store.clear()
    }

    @Test("a group the app is not entitled to is a typed error")
    func otherGroup() async throws {
        defer { cleanUp() }
        let group = try #require(StrideApp.appGroup)
        let store = try makeStore(accessGroup: "\(group.keychainAccessGroup).other")

        await #expect(throws: AuthStoreError.keychain(errSecMissingEntitlement)) {
            try await store.save(pair)
        }
    }

    /// Removes the marker at the end, so the next launch has to write it again and
    /// this test cannot pass on an old one. That signs the simulator's app out.
    @Test("the app marks its install when it launches", .timeLimit(.minutes(1)))
    func launch() async throws {
        let container = try #require(StrideApp.appGroup?.containerURL())
        let marker = InstallMarker(container: container)
        #expect(StrideApp.authStore != nil)

        while marker.exists == false {
            try await Task.sleep(for: .milliseconds(100))
        }

        try FileManager.default.removeItem(at: marker.url)
    }

    /// Stands for the app group container.
    private var container: URL {
        URL.temporaryDirectory.appending(path: service, directoryHint: .isDirectory)
    }

    private func cleanUp() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
        try? FileManager.default.removeItem(at: container)
    }

    private func makeStore(accessGroup: String) throws -> AuthStore {
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let marker = InstallMarker(container: container)
        try marker.create()

        return AuthStore(
            accessGroup: accessGroup,
            service: service,
            marker: marker,
            keychain: SystemKeychainClient()
        )
    }

    private func storedAttributes() -> [String: Any]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        SecItemCopyMatching(query as CFDictionary, &result)

        return result as? [String: Any]
    }
}
