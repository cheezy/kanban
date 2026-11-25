import Foundation

@testable import StrideKit

extension TokenPair {
    /// A pair of made-up tokens that differ for each number.
    static func example(_ number: Int = 1) -> TokenPair {
        TokenPair(
            accessToken: "EXAMPLE-access-\(number)",
            accessTokenExpiresAt: Date(timeIntervalSince1970: 1_800_000_000.25 + Double(number)),
            refreshToken: "EXAMPLE-refresh-\(number)"
        )
    }
}
