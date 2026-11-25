import Foundation
import Security

/// A generic password in `FakeKeychain`, or the attributes a query asks for.
struct KeychainItem: Equatable, Sendable {
    var itemClass: String?
    var service: String?
    var account: String?
    var accessGroup: String?
    var accessible: String?
    var data: Data?

    init(
        service: String,
        account: String,
        accessGroup: String,
        data: Data
    ) {
        itemClass = kSecClassGenericPassword as String
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
        self.data = data
    }

    init(_ attributes: [String: Any]) {
        itemClass = attributes[kSecClass as String] as? String
        service = attributes[kSecAttrService as String] as? String
        account = attributes[kSecAttrAccount as String] as? String
        accessGroup = attributes[kSecAttrAccessGroup as String] as? String
        accessible = attributes[kSecAttrAccessible as String] as? String
        data = attributes[kSecValueData as String] as? Data
    }

    func hasSameKey(as other: KeychainItem) -> Bool {
        (itemClass, service, account, accessGroup)
            == (other.itemClass, other.service, other.account, other.accessGroup)
    }

    /// Whether `item` has every key attribute this one, as a query, asks for.
    func matches(_ item: KeychainItem) -> Bool {
        (itemClass == nil || itemClass == item.itemClass)
            && (service == nil || service == item.service)
            && (account == nil || account == item.account)
            && (accessGroup == nil || accessGroup == item.accessGroup)
    }
}
