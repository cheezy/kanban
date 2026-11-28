import Foundation
import StrideKit

/// What the exploratory testing row says.
enum ReviewExploratoryResult: Hashable, Sendable {
    case findings(Int)
    /// No structured block was stored, so the notes are on the web.
    case seeNotesOnWeb

    init(_ exploratory: Components.Schemas.ReviewExploratory) {
        self = exploratory.count.map(Self.findings) ?? .seeNotesOnWeb
    }
}
