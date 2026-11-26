import Foundation

public enum CacheError: Error, Equatable, Sendable {
    /// The store cannot be read now, as while the phone is locked, or could not
    /// be opened even after a reset.
    case unavailable
    /// The cache was wiped after the response set out, so it is not kept.
    case superseded
    /// The entry it belongs to, such as a file's review, is not cached.
    case parentNotCached
    /// The value could not be encoded.
    case invalidValue
}
