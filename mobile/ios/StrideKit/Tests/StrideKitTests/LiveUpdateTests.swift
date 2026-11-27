import Foundation
import Testing

@testable import StrideKit

struct LiveUpdateTests {
    @Test("a decisions push reads as the inbox the API returns")
    func decisions() async throws {
        let payload = try FixtureAPI.fixture(named: Operations.ListMyDecisions.id)
        let fetched = try await FixtureAPI().client.listMyDecisions().ok.body.json.data

        #expect(LiveUpdate(topic: .inbox, event: "decisions", payload: payload) == .decisions(fetched))
    }

    @Test("an agents push reads as the agents the API returns")
    func agents() async throws {
        let payload = try FixtureAPI.fixture(named: Operations.ListMyAgents.id)
        let fetched = try await FixtureAPI().client.listMyAgents().ok.body.json.data

        #expect(LiveUpdate(topic: .agents, event: "agents", payload: payload) == .agents(fetched))
    }

    @Test("an event the topic does not send is ignored")
    func wrongEvent() throws {
        let payload = try FixtureAPI.fixture(named: Operations.ListMyDecisions.id)

        #expect(LiveUpdate(topic: .inbox, event: "agents", payload: payload) == nil)
        #expect(LiveUpdate(topic: .inbox, event: "phx_reply", payload: payload) == nil)
    }

    @Test("a payload of the wrong shape is ignored")
    func wrongShape() throws {
        let agents = try FixtureAPI.fixture(named: Operations.ListMyAgents.id)

        #expect(LiveUpdate(topic: .inbox, event: "decisions", payload: agents) == nil)
        #expect(LiveUpdate(topic: .agents, event: "agents", payload: Data("not json".utf8)) == nil)
        #expect(LiveUpdate(topic: .agents, event: "agents", payload: Data("{}".utf8)) == nil)
    }

    @Test("each topic is the server's channel and event")
    func topics() {
        #expect(LiveTopic.inbox.rawValue == "me:inbox")
        #expect(LiveTopic.inbox.event == "decisions")
        #expect(LiveTopic.agents.rawValue == "me:agents")
        #expect(LiveTopic.agents.event == "agents")
    }

    @Test("connects to the Stride server's socket")
    func endpoint() {
        #expect(PhoenixConnection.endpoint.absoluteString == "https://www.stridelikeaboss.com/api/socket")
    }
}
