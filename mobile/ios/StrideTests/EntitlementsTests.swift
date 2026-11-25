import Foundation
import Security
import Testing

@testable import Stride

struct EntitlementsTests {
    private static let appGroups = "com.apple.security.application-groups"
    private static let keychainGroups = "keychain-access-groups"

    @Test("the app embeds the widgets and the notification service")
    func embeddedExtensions() throws {
        let names = try BuiltBundle.embeddedExtensions().keys.sorted()

        #expect(names == ["StrideNotificationService", "StrideWidgets"])
    }

    @Test(
        "both extensions see the same app group and keychain group as the app",
        arguments: ["StrideNotificationService", "StrideWidgets"]
    )
    func sharedGroups(name: String) throws {
        let embedded = try #require(try BuiltBundle.embeddedExtensions()[name])
        let app = BuiltBundle.app
        let appGroup = try #require(app.infoString("StrideAppGroup"))
        let keychainGroup = try #require(app.infoString("StrideKeychainGroup"))

        for bundle in [app, embedded] {
            let entitlements = try bundle.entitlements()

            #expect(entitlements[Self.appGroups] as? [String] == [appGroup])
            #expect(entitlements[Self.keychainGroups] as? [String] == [keychainGroup])
            #expect(bundle.infoString("StrideAppGroup") == appGroup)
            #expect(bundle.infoString("StrideKeychainGroup") == keychainGroup)
        }
    }

    @Test("the app has only the entitlements Phase 1 needs")
    func appEntitlements() throws {
        let entitlements = try BuiltBundle.app.entitlements()

        #expect(entitlements.keys.sorted() == [
            "aps-environment",
            "com.apple.developer.associated-domains",
            Self.appGroups,
            Self.keychainGroups
        ])
        #expect(entitlements["com.apple.developer.associated-domains"] as? [String] == ["applinks:www.stridelikeaboss.com"])
    }

    @Test(
        "an extension has only the two shared groups",
        arguments: ["StrideNotificationService", "StrideWidgets"]
    )
    func extensionEntitlements(name: String) throws {
        let embedded = try #require(try BuiltBundle.embeddedExtensions()[name])

        #expect(try embedded.entitlements().keys.sorted() == [Self.appGroups, Self.keychainGroups])
    }

    @Test("the app can use the keychain group it names, and no other")
    func keychainGroup() async throws {
        let group = try #require(await StrideApp.appGroup)

        #expect(addAndRemoveItem(in: group.keychainAccessGroup) == errSecSuccess)
        #expect(addAndRemoveItem(in: "\(group.keychainAccessGroup).other") == errSecMissingEntitlement)
    }

    private func addAndRemoveItem(in accessGroup: String) -> OSStatus {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "EntitlementsTests",
            kSecAttrAccount as String: UUID().uuidString,
            kSecAttrAccessGroup as String: accessGroup
        ]
        let added = item.merging([kSecValueData as String: Data([1])]) { $1 }
        defer { SecItemDelete(item as CFDictionary) }

        return SecItemAdd(added as CFDictionary, nil)
    }
}
