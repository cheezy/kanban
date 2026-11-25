import Foundation
import Testing

@testable import StrideKit

struct TokenPairTests {
    @Test("shows no token when it is printed, dumped or reflected")
    func showsNoToken() {
        let pair = TokenPair.example()
        var dumped = ""
        dump(["pair": pair], to: &dumped)

        for text in ["\(pair)", String(reflecting: pair), "\([pair])", dumped] {
            #expect(text.contains("EXAMPLE") == false)
        }
        #expect(Mirror(reflecting: pair).children.isEmpty)
    }
}
