import Foundation
import StrideKit

/// The counts above the Now cards, taken by the server before it caps the list.
struct NowSummary: Hashable, Sendable {
    var waiting = 0
    var heldUp = 0
    var agentsWorking = 0

    init(waiting: Int = 0, heldUp: Int = 0, agentsWorking: Int = 0) {
        self.waiting = max(0, waiting)
        self.heldUp = max(0, heldUp)
        self.agentsWorking = max(0, agentsWorking)
    }

    init(_ summary: Components.Schemas.DecisionSummary) {
        self.init(waiting: summary.waiting, heldUp: summary.heldUp, agentsWorking: summary.agentsWorking)
    }
}
