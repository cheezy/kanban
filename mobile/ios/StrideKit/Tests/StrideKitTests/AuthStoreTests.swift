import Foundation
import Security
import Testing

@testable import StrideKit

@Suite(.timeLimit(.minutes(1)))
struct AuthStoreTests {
    private static let accessGroup = "TEAM.example.shared"

    private let container: TemporaryDirectory
    private let keychain = FakeKeychain()
    private let marker: InstallMarker
    private let store: AuthStore

    /// Starts in an install that has launched before.
    init() throws {
        container = try TemporaryDirectory()
        marker = InstallMarker(container: container.url)
        try marker.create()
        store = AuthStore(accessGroup: Self.accessGroup, marker: marker, keychain: keychain)
    }

    // MARK: Saving and reading

    @Test("saves and reads a token pair")
    func saveAndRead() async throws {
        try await store.save(.example())

        #expect(try await store.read() == .example())
    }

    @Test("reading with nothing stored returns nil")
    func readNothing() async throws {
        #expect(try await store.read() == nil)
    }

    @Test("keeps one item, in the shared access group, readable after the first unlock on this device only")
    func item() async throws {
        try await store.save(.example())

        let item = try #require(keychain.items.first)
        #expect(keychain.items.count == 1)
        #expect(item.itemClass == kSecClassGenericPassword as String)
        #expect(item.service == AuthStore.service)
        #expect(item.account == AuthStore.account)
        #expect(item.accessGroup == Self.accessGroup)
        #expect(item.accessible == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    @Test("writes no token to the app group container")
    func nothingInContainer() async throws {
        try await store.save(.example())

        let files = try FileManager.default.contentsOfDirectory(atPath: container.url.path())
        #expect(files == [marker.url.lastPathComponent])
        #expect(try Data(contentsOf: marker.url).isEmpty)
    }

    @Test("a second sign-in replaces the pair and the item's accessibility")
    func saveAgain() async throws {
        var old = ownItem(data: Data("old".utf8))
        old.accessible = kSecAttrAccessibleWhenUnlocked as String
        keychain.insert(old)

        try await store.save(.example(2))

        #expect(try await store.read() == .example(2))
        #expect(keychain.items.count == 1)
        #expect(
            keychain.items.first?.accessible == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }

    @Test("reads what another process wrote")
    func readsOtherProcess() async throws {
        let other = AuthStore(accessGroup: Self.accessGroup, marker: marker, keychain: keychain)
        try await store.save(.example(1))
        #expect(try await other.read() == .example(1))

        try await other.rotate(from: .example(1), to: .example(2))

        #expect(try await store.read() == .example(2))
    }

    @Test("has no store when the target is not entitled to the app group")
    func noContainer() throws {
        let group = try #require(AppGroup(infoDictionary: [
            AppGroup.identifierKey: "group.example",
            AppGroup.keychainAccessGroupKey: Self.accessGroup
        ]))

        let unentitled = AuthStore(group: group) { _ in nil }
        let entitled = AuthStore(group: group) { [url = container.url] _ in url }

        #expect(unentitled == nil)
        #expect(entitled != nil)
    }

    // MARK: Rotating

    @Test("rotating replaces both tokens")
    func rotate() async throws {
        try await store.save(.example(1))

        try await store.rotate(from: .example(1), to: .example(2))

        #expect(try await store.read() == .example(2))
        #expect(keychain.items.count == 1)
    }

    @Test("concurrent rotate calls leave one consistent pair")
    func concurrentRotations() async throws {
        try await store.save(.example(0))

        let winners = await withTaskGroup(of: Int?.self) { group in
            for number in 1...50 {
                group.addTask { [store] in
                    do {
                        try await store.rotate(from: .example(0), to: .example(number))
                        return number
                    } catch {
                        #expect(error as? AuthStoreError == .superseded)
                        return nil
                    }
                }
            }
            return await group.reduce(into: [Int]()) { winners, number in
                if let number { winners.append(number) }
            }
        }

        let winner = try #require(winners.first)
        #expect(winners.count == 1)
        #expect(try await store.read() == .example(winner))
    }

    @Test("a rotation that ends after a sign-out stores nothing")
    func rotateAfterClear() async throws {
        try await store.save(.example(1))
        try await store.clear()

        await #expect(throws: AuthStoreError.superseded) {
            try await store.rotate(from: .example(1), to: .example(2))
        }

        #expect(keychain.items.isEmpty)
    }

    @Test("a rotation stores nothing when the item goes between its read and its write")
    func rotateWhileCleared() async throws {
        try await store.save(.example(1))
        keychain.fail(.update, with: errSecItemNotFound)

        await #expect(throws: AuthStoreError.superseded) {
            try await store.rotate(from: .example(1), to: .example(2))
        }

        #expect(try await store.read() == .example(1))
    }

    // MARK: Clearing

    @Test("clear removes every item")
    func clear() async throws {
        let others = [
            KeychainItem(service: "Other", account: "a", accessGroup: Self.accessGroup, data: Data()),
            KeychainItem(service: AuthStore.service, account: "a", accessGroup: "other", data: Data())
        ]
        others.forEach(keychain.insert)
        keychain.insert(ownItem(account: "older-version", data: Data()))
        try await store.save(.example())

        try await store.clear()

        #expect(keychain.items == others)
        #expect(try await store.read() == nil)
    }

    @Test("clearing with nothing stored is not an error")
    func clearNothing() async throws {
        try await store.clear()

        #expect(keychain.items.isEmpty)
    }

    // MARK: A previous install

    @Test("a previous install's items are cleared on first launch")
    func previousInstall() async throws {
        let store = try await reinstall()

        try await store.clearItemsFromPreviousInstall()

        #expect(keychain.items.isEmpty)
        #expect(marker.exists)
        #expect(try await store.read() == nil)
    }

    @Test("a later launch keeps the pair")
    func laterLaunch() async throws {
        try await store.save(.example())

        try await store.clearItemsFromPreviousInstall()

        #expect(try await store.read() == .example())
    }

    @Test("an extension that runs before the app reads no previous install's pair and removes nothing")
    func extensionBeforeApp() async throws {
        let store = try await reinstall()

        #expect(try await store.read() == nil)
        await #expect(throws: AuthStoreError.superseded) {
            try await store.rotate(from: .example(), to: .example(2))
        }
        #expect(keychain.items.count == 1)
        #expect(marker.exists == false)
    }

    @Test("a sign-in before the first launch clear keeps only its own pair")
    func saveBeforeClear() async throws {
        let store = try await reinstall()
        keychain.insert(ownItem(account: "older-version", data: Data()))

        try await store.save(.example(2))
        try await store.clearItemsFromPreviousInstall()

        #expect(keychain.items.count == 1)
        #expect(try await store.read() == .example(2))
    }

    @Test("a first launch with nothing stored marks the install")
    func firstInstall() async throws {
        try FileManager.default.removeItem(at: marker.url)

        try await store.clearItemsFromPreviousInstall()

        #expect(marker.exists)
    }

    @Test("a first launch that cannot clear the items leaves the install unmarked and tries again")
    func clearFails() async throws {
        let store = try await reinstall()
        keychain.fail(.delete, with: errSecInteractionNotAllowed)

        await #expect(throws: AuthStoreError.keychain(errSecInteractionNotAllowed)) {
            try await store.clearItemsFromPreviousInstall()
        }
        #expect(marker.exists == false)
        #expect(try await store.read() == nil)

        keychain.recover()
        try await store.clearItemsFromPreviousInstall()
        #expect(keychain.items.isEmpty)
        #expect(marker.exists)
    }

    @Test("an install that cannot be marked is an error, and its items are still cleared")
    func markerFails() async throws {
        let store = try await reinstall()
        try FileManager.default.removeItem(at: container.url)

        await #expect(throws: AuthStoreError.installNotMarked) {
            try await store.clearItemsFromPreviousInstall()
        }
        #expect(keychain.items.isEmpty)
    }

    // MARK: Errors

    @Test("a Keychain failure surfaces as a typed error")
    func keychainFailures() async throws {
        try await store.save(.example(1))
        let denied = AuthStoreError.keychain(errSecInteractionNotAllowed)
        for call in [FakeKeychain.Call.add, .copyData, .update, .delete] {
            keychain.fail(call, with: errSecInteractionNotAllowed)
        }

        await #expect(throws: denied) { try await store.read() }
        await #expect(throws: denied) { try await store.save(.example(2)) }
        await #expect(throws: denied) { try await store.rotate(from: .example(1), to: .example(2)) }
        await #expect(throws: denied) { try await store.clear() }
        await #expect(throws: denied) { try await store.signedIn() }

        keychain.recover()
        #expect(try await store.read() == .example(1))
    }

    @Test("a failure to replace the item surfaces as a typed error")
    func updateFails() async throws {
        try await store.save(.example(1))
        keychain.fail(.update, with: errSecNotAvailable)
        let failed = AuthStoreError.keychain(errSecNotAvailable)

        await #expect(throws: failed) { try await store.save(.example(2)) }
        await #expect(throws: failed) { try await store.rotate(from: .example(1), to: .example(2)) }
        #expect(try await store.read() == .example(1))
    }

    @Test("an item that is not a token pair is an error, and a sign-in replaces it")
    func invalidItem() async throws {
        keychain.insert(ownItem(data: Data("{}".utf8)))
        await #expect(throws: AuthStoreError.invalidPair) { try await store.read() }

        try await store.save(.example())

        #expect(try await store.read() == .example())
    }

    @Test("a pair that cannot be encoded is an error and stores nothing")
    func unencodablePair() async throws {
        let pair = TokenPair(
            accessToken: "EXAMPLE-access",
            accessTokenExpiresAt: Date(timeIntervalSinceReferenceDate: .infinity),
            refreshToken: "EXAMPLE-refresh"
        )

        await #expect(throws: AuthStoreError.invalidPair) { try await store.save(pair) }
        #expect(keychain.items.isEmpty)
    }

    // MARK: The signed-in stream

    @Test("the signed-in stream starts with the current state and follows sign-in and sign-out")
    func signedInStream() async throws {
        var states = try await store.signedIn().makeAsyncIterator()
        #expect(await states.next() == false)

        try await store.save(.example(1))
        #expect(await states.next() == true)

        try await store.clear()
        #expect(await states.next() == false)
    }

    @Test("a stream opened while signed in starts signed in, and each stream gets each change")
    func twoStreams() async throws {
        try await store.save(.example())
        var first = try await store.signedIn().makeAsyncIterator()
        var second = try await store.signedIn().makeAsyncIterator()
        #expect(await first.next() == true)
        #expect(await second.next() == true)

        try await store.clear()

        #expect(await first.next() == false)
        #expect(await second.next() == false)
    }

    @Test("a slow reader gets only the latest state")
    func latestState() async throws {
        var states = try await store.signedIn().makeAsyncIterator()

        try await store.save(.example())
        try await store.clear()
        try await store.save(.example())

        #expect(await states.next() == true)
    }

    @Test("a sign-out that fails is not announced")
    func failedClear() async throws {
        try await store.save(.example())
        var states = try await store.signedIn().makeAsyncIterator()
        keychain.fail(.delete, with: errSecNotAvailable)

        await #expect(throws: AuthStoreError.keychain(errSecNotAvailable)) {
            try await store.clear()
        }

        // Read only now: the stream keeps its latest state, so a sign-out it was
        // told of would have replaced the first one.
        #expect(await states.next() == true)
    }

    @Test("a cancelled reader is forgotten")
    func cancelledReader() async throws {
        let states = try await store.signedIn()
        let reader = Task {
            for await _ in states {}
        }
        #expect(await store.observerCount == 1)

        reader.cancel()

        while await store.observerCount > 0 {
            await Task.yield()
        }
    }

    @Test("the stream ends with its store")
    func streamEnds() async throws {
        var store: AuthStore? = AuthStore(
            accessGroup: Self.accessGroup,
            marker: marker,
            keychain: keychain
        )
        var states = try #require(try await store?.signedIn()).makeAsyncIterator()
        #expect(await states.next() == false)

        store = nil

        #expect(await states.next() == nil)
    }

    /// The app deleted and installed again: its items stay, its container goes.
    private func reinstall() async throws -> AuthStore {
        try await store.save(.example())
        try FileManager.default.removeItem(at: marker.url)

        return AuthStore(accessGroup: Self.accessGroup, marker: marker, keychain: keychain)
    }

    private func ownItem(account: String = AuthStore.account, data: Data) -> KeychainItem {
        KeychainItem(
            service: AuthStore.service,
            account: account,
            accessGroup: Self.accessGroup,
            data: data
        )
    }
}
