#if DEBUG
import Foundation
import StrideKit

/// A debug build that signs in through the stub and is started with
/// `-StrideStubLargeReview` answers every review as one the server lets no
/// phone approve (`FixtureAPI.largeReview`), so the large-change notice and
/// Approve on tablet or web can be seen and tested.
enum StubLargeReview {
    nonisolated static let argument = "-StrideStubLargeReview"

    /// The fixtures' replacements for `arguments`: the large review, or none.
    static func replacements(arguments: [String]) -> [String: Data] {
        guard arguments.contains(argument) else { return [:] }

        return (try? FixtureAPI.largeReview) ?? [:]
    }
}
#endif
