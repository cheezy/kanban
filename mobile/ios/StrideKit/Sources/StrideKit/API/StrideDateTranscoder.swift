import Foundation
import OpenAPIRuntime

/// Reads every date-time the contract allows: with or without fractional
/// seconds, in any offset. The runtime's own transcoders each read only one.
struct StrideDateTranscoder: DateTranscoder {
    private let wholeSeconds: ISO8601DateTranscoder = .iso8601
    private let fractionalSeconds: ISO8601DateTranscoder = .iso8601WithFractionalSeconds

    func encode(_ date: Date) throws -> String {
        try wholeSeconds.encode(date)
    }

    func decode(_ string: String) throws -> Date {
        if let date = try? fractionalSeconds.decode(string) { return date }
        return try wholeSeconds.decode(string)
    }
}
