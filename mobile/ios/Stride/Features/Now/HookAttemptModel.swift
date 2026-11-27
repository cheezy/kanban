import Foundation
import Observation
import StrideKit

/// The View attempt sheet: a failed goal's last after_goal attempt, asked of
/// the server when the sheet opens.
@MainActor
@Observable
final class HookAttemptModel {
    enum State: Hashable, Sendable {
        case loading
        case loaded(HookAttempt)
        case unavailable
    }

    let cardID: NowCard.ID
    let goalID: Int
    /// The goal's identifier, such as G88, from the card.
    let identifier: String
    private(set) var state = State.loading

    @ObservationIgnored private let api: (any StrideAPI)?

    init(cardID: NowCard.ID, goalID: Int, identifier: String, api: (any StrideAPI)?) {
        self.cardID = cardID
        self.goalID = goalID
        self.identifier = identifier
        self.api = api
    }

    func load() async {
        guard let api else {
            state = .unavailable
            return
        }

        state = await Self.fetch(goalID, using: api).map(State.loaded) ?? .unavailable
    }

    private nonisolated static func fetch(_ goalID: Int, using api: any StrideAPI) async -> HookAttempt? {
        guard
            case .ok(let response) = try? await api.getMyGoalAfterGoal(path: .init(id: goalID)),
            let attempt = try? response.body.json.data
        else { return nil }

        return HookAttempt(attempt)
    }
}
