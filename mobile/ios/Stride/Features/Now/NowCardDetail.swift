import Foundation

/// What a Now card shows besides its title, by kind. The strings come from the
/// server and are shown as plain text.
enum NowCardDetail: Hashable, Sendable {
    case review
    case released(reason: String?, agent: AgentAvatarContent?)
    case claimExpired(agent: String?, minutes: Int?)
    case hookFailed(exitCode: Int?, duration: Duration?)
    case readyEmpty(board: String, idleAgents: Int, backlogCount: Int)
}
