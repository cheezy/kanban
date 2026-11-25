import Foundation
import Security

/// The device's Keychain.
struct SystemKeychainClient: KeychainClient {
    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func copyData(matching query: [String: Any]) -> (status: OSStatus, data: Data?) {
        let one: [String: Any] = [
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query.merging(one) { $1 } as CFDictionary, &result)

        return (status, result as? Data)
    }

    func update(_ query: [String: Any], to attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}
