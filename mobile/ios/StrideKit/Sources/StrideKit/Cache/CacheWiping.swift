import Foundation

/// Wipes the cache, which the app does whenever the device is signed out.
public protocol CacheWiping: Sendable {
    func wipe() async throws(CacheError)
}

extension Cache: CacheWiping {}
