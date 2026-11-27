import Foundation

/// The full state a channel pushed. A channel sends all of it on join and after
/// each change, never a difference, so the newest update replaces the one before.
public enum LiveUpdate: Sendable, Equatable {
    /// What waits on the person, as `listMyDecisions` returns it.
    case decisions(Components.Schemas.DecisionList)

    /// The person's agents and goals, as `listMyAgents` returns them.
    case agents(Components.Schemas.MeAgents)

    /// Reads a push as the body of the matching API call. Nil for an event the
    /// topic does not send or a payload that does not decode: a push is data, and
    /// nothing in it is acted on.
    init?(topic: LiveTopic, event: String, payload: Data) {
        guard event == topic.event else { return nil }

        let decoder = Self.decoder
        switch topic {
        case .inbox:
            guard let body = try? decoder.decode(Components.Schemas.DecisionListResponse.self, from: payload) else {
                return nil
            }
            self = .decisions(body.data)
        case .agents:
            guard let body = try? decoder.decode(Components.Schemas.MeAgentsResponse.self, from: payload) else {
                return nil
            }
            self = .agents(body.data)
        }
    }

    /// Reads dates the way the API client does, with or without fractions.
    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        let transcoder = StrideDateTranscoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            try transcoder.decode(decoder.singleValueContainer().decode(String.self))
        }
        return decoder
    }
}
