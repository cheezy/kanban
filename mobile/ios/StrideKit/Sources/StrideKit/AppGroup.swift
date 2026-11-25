import Foundation

/// The app group and keychain access group the app and its extensions share.
///
/// Both names come from the target's Info.plist, which takes them from the build
/// settings in `project.yml`. The keychain group needs its team prefix, and only
/// the built Info.plist has it.
public struct AppGroup: Equatable, Sendable {
    static let identifierKey = "StrideAppGroup"
    static let keychainAccessGroupKey = "StrideKeychainGroup"

    public let identifier: String
    public let keychainAccessGroup: String

    /// Returns nil when the bundle's Info.plist does not name both groups.
    public init?(bundle: Bundle) {
        self.init(infoDictionary: bundle.infoDictionary ?? [:])
    }

    init?(infoDictionary: [String: Any]) {
        guard
            let identifier = infoDictionary[Self.identifierKey] as? String,
            let keychainAccessGroup = infoDictionary[Self.keychainAccessGroupKey] as? String,
            identifier.isEmpty == false,
            keychainAccessGroup.isEmpty == false
        else { return nil }

        self.identifier = identifier
        self.keychainAccessGroup = keychainAccessGroup
    }

    /// The directory the app and its extensions share, or nil when the running
    /// target is not entitled to the group.
    public func containerURL(resolve: (String) -> URL? = Self.systemContainerURL) -> URL? {
        resolve(identifier)
    }

    public static func systemContainerURL(for identifier: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
