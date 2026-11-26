import Foundation
import Security
import os

@testable import StrideKit

/// A Keychain in memory. It matches items by service, account and access group,
/// and refuses a call with the status a test sets for it, for every item or for
/// one account's.
final class FakeKeychain: KeychainClient {
    enum Call: Hashable {
        case add, copyData, update, delete
    }

    private struct Failure {
        let status: OSStatus
        let account: String?
    }

    private struct State {
        var items: [KeychainItem] = []
        var failures: [Call: Failure] = [:]

        /// The status that refuses `call` on `account`, if a test set one.
        func failure(of call: Call, on account: String?) -> OSStatus? {
            guard let failure = failures[call], failure.account == nil || failure.account == account else {
                return nil
            }
            return failure.status
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var items: [KeychainItem] {
        state.withLock { $0.items }
    }

    func insert(_ item: KeychainItem) {
        state.withLock { $0.items.append(item) }
    }

    /// Refuses `call` with `status`, on every item or only on `account`'s.
    func fail(_ call: Call, with status: OSStatus, account: String? = nil) {
        state.withLock { $0.failures[call] = Failure(status: status, account: account) }
    }

    func recover() {
        state.withLock { $0.failures = [:] }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        let item = KeychainItem(attributes)

        return state.withLock { state in
            if let failure = state.failure(of: .add, on: item.account) { return failure }
            if state.items.contains(where: { $0.hasSameKey(as: item) }) { return errSecDuplicateItem }

            state.items.append(item)
            return errSecSuccess
        }
    }

    func copyData(matching query: [String: Any]) -> (status: OSStatus, data: Data?) {
        let wanted = KeychainItem(query)

        return state.withLock { state in
            if let failure = state.failure(of: .copyData, on: wanted.account) { return (failure, nil) }
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
            if let failure = state.failure(of: .update, on: wanted.account) { return failure }
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
            if let failure = state.failure(of: .delete, on: wanted.account) { return failure }
            guard state.items.contains(where: wanted.matches) else { return errSecItemNotFound }

            state.items.removeAll(where: wanted.matches)
            return errSecSuccess
        }
    }
}
