import Foundation
import Security

/// The four Keychain calls `AuthStore` makes, so that tests can replace them.
/// Each takes the attribute dictionary of the `SecItem` function it stands for.
protocol KeychainClient: Sendable {
    func add(_ attributes: [String: Any]) -> OSStatus
    func copyData(matching query: [String: Any]) -> (status: OSStatus, data: Data?)
    func update(_ query: [String: Any], to attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}
