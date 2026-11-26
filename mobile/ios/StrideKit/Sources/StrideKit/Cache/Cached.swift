import Foundation

/// A cached response and the time it was fetched, which the offline banner shows.
public struct Cached<Value: Sendable>: Sendable {
    public let value: Value
    public let fetchedAt: Date
}

extension Cached: Equatable where Value: Equatable {}
