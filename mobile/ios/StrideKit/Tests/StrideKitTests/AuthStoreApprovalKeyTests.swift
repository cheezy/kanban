import Foundation
import Security
import Testing

@testable import StrideKit

@Suite(.timeLimit(.minutes(1)))
struct AuthStoreApprovalKeyTests {
    private static let accessGroup = "TEAM.example.shared"

    private let container: TemporaryDirectory
    private let keychain = FakeKeychain()
    private let marker: InstallMarker
    private let store: AuthStore
    private let key = ApprovalKey.example()

    init() throws {
        container = try TemporaryDirectory()
        marker = InstallMarker(container: container.url)
        try marker.create()
        store = AuthStore(accessGroup: Self.accessGroup, marker: marker, keychain: keychain)
    }

    @Test("a sign-in keeps the pair and the approval key")
    func save() async throws {
        try await store.save(.example(), approvalKey: key)

        #expect(try await store.read() == .example())
        #expect(try await store.approvalKeyHandle() == key.handle)
    }

    @Test("keeps the key as a second item of the same service, on this device only")
    func item() async throws {
        try await store.save(.example(), approvalKey: key)

        let item = try #require(keychain.items.first { $0.account == AuthStore.approvalKeyAccount })
        #expect(keychain.items.count == 2)
        #expect(item.service == AuthStore.service)
        #expect(item.accessGroup == Self.accessGroup)
        #expect(item.accessible == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(item.data == key.handle)
    }

    @Test("announces the sign-in once")
    func announces() async throws {
        var states = try await store.signedIn().makeAsyncIterator()
        #expect(await states.next() == false)

        try await store.save(.example(), approvalKey: key)

        #expect(await states.next() == true)
    }

    @Test("a second sign-in replaces the key")
    func replace() async throws {
        let second = ApprovalKey.example()
        try await store.save(.example(1), approvalKey: key)

        try await store.save(.example(2), approvalKey: second)

        #expect(try await store.read() == .example(2))
        #expect(try await store.approvalKeyHandle() == second.handle)
        #expect(keychain.items.count == 2)
    }

    @Test("signing out removes the key with the pair")
    func clear() async throws {
        try await store.save(.example(), approvalKey: key)

        try await store.clear()

        #expect(try await store.approvalKeyHandle() == nil)
        #expect(keychain.items.isEmpty)
    }

    @Test("a refused refresh removes the key with the pair")
    func clearRefused() async throws {
        try await store.save(.example(), approvalKey: key)

        try await store.clear(refused: .example())

        #expect(keychain.items.isEmpty)
    }

    @Test("a key left by a previous install is removed before the new one is kept, and never read")
    func previousInstall() async throws {
        try await store.save(.example(1), approvalKey: key)
        try FileManager.default.removeItem(at: marker.url)
        let reinstalled = AuthStore(accessGroup: Self.accessGroup, marker: marker, keychain: keychain)

        #expect(try await reinstalled.approvalKeyHandle() == nil)

        let second = ApprovalKey.example()
        try await reinstalled.save(.example(2), approvalKey: second)

        #expect(try await reinstalled.approvalKeyHandle() == second.handle)
        #expect(keychain.items.count == 2)
    }

    @Test("a Keychain that refuses the key stores no pair")
    func keyRefused() async throws {
        // Only the key's item, so the pair's own write could not hide the order.
        keychain.fail(.add, with: errSecInteractionNotAllowed, account: AuthStore.approvalKeyAccount)

        await #expect(throws: AuthStoreError.self) {
            try await store.save(.example(), approvalKey: key)
        }

        keychain.recover()
        #expect(try await store.read() == nil)
        #expect(try await store.approvalKeyHandle() == nil)
    }
}
