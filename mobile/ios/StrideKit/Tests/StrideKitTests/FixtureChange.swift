import Foundation
import Testing

@testable import StrideKit

/// A shared fixture with its first record changed, for a response the shared
/// fixtures do not have. They hold one example each, checked by the server's tests.
enum FixtureChange {
    static func body(of operationID: String, _ change: (inout [String: Any]) -> Void) throws -> Data {
        let json = try JSONSerialization.jsonObject(with: FixtureAPI.fixture(named: operationID))
        var body = try #require(json as? [String: Any])
        change(&body)
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Changes the first item of a list, at `data` or at `data.items`.
    static func firstItem(of operationID: String, _ change: (inout [String: Any]) -> Void) throws -> Data {
        try body(of: operationID) { body in
            if var items = body["data"] as? [[String: Any]] {
                change(&items[0])
                body["data"] = items
            } else if var page = body["data"] as? [String: Any], var items = page["items"] as? [[String: Any]] {
                change(&items[0])
                page["items"] = items
                body["data"] = page
            }
        }
    }
}
