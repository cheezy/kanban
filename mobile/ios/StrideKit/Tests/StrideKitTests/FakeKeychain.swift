import Foundation
import Security
import os

@testable import StrideKit

/// A Keychain in memory. It matches items by service, account and access group,
/// and refuses a call with the status a test sets for it.
final class FakeKeychain: KeychainClient {
    enum Call: Hashable {
        case add, copyData, update, delete
    }

    private struct State {
        var items: [KeychainItem] = []
        var failures: [Call: OSStatus] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var items: [KeychainItem] {
        state.withLock { $0.items }
    }

    func insert(_ item: KeychainItem) {
        state.withLock { $0.items.append(item) }
    }

    func fail(_ call: Call, with status: OSStatus) {
        state.withLock { $0.failures[call] = status }
    }

    func recover() {
        state.withLock { $0.failures = [:] }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        let item = KeychainItem(attributes)

        return state.withLock { state in
            if let failure = state.failures[.add] { return failure }
            if state.items.contains(where: { $0.hasSameKey(as: item) }) { return errSecDuplicateItem }

            state.items.append(item)
            return errSecSuccess
        }
    }

    func copyData(matching query: [String: Any]) -> (status: OSStatus, data: Data?) {
        let wanted = KeychainItem(query)

        return state.withLock { state in
            if let failure = state.failures[.copyData] { return (failure, nil) }
            guard let item = state.items.first(where: wanted.matches) else {
                return (errSecItemNotFound, nil)
            }

            return (errSecSuccess, item.data)
        }
    }

    func update(_ query: [String: Any], to attributes: [String: Any]) -> OSStatus {
        let wanted = KeychainItem(query)
        let changes = KeychainItem(attributes)

        return state.withLock { state in
            if let failure = state.failures[.update] { return failure }
            guard state.items.contains(where: wanted.matches) else { return errSecItemNotFound }

            for index in state.items.indices where wanted.matches(state.items[index]) {
                state.items[index].data = changes.data ?? state.items[index].data
                state.items[index].accessible = changes.accessible ?? state.items[index].accessible
            }
            return errSecSuccess
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        let wanted = KeychainItem(query)

        return state.withLock { state in
            if let failure = state.failures[.delete] { return failure }
            guard state.items.contains(where: wanted.matches) else { return errSecItemNotFound }

            state.items.removeAll(where: wanted.matches)
            return errSecSuccess
        }
    }
}
