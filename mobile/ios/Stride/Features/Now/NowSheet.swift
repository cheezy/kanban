import Foundation

/// A sheet a Now card's action opens over the screen.
enum NowSheet: Identifiable {
    case reply(ReplyModel)
    case attempt(HookAttemptModel)

    var id: String {
        switch self {
        case .reply(let reply): "reply-\(reply.cardID)"
        case .attempt(let attempt): "attempt-\(attempt.cardID)"
        }
    }
}
