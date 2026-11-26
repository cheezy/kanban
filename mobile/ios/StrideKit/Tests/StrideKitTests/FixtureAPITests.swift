import Foundation
import Testing

@testable import StrideKit

struct FixtureAPITests {
    @Test("answers the operations that have no body")
    func noContent() async throws {
        let api = FixtureAPI().client

        _ = try await api.signOutCurrentDevice().noContent
        _ = try await api.revokeMyDevice(path: .init(id: 1)).noContent
    }

    @Test("a replaced body is served for its own operation only")
    func replacedBody() async throws {
        let data = Data(#"{"data": []}"#.utf8)
        let api = FixtureAPI(replacing: [Operations.ListMyBoards.id: data]).client

        #expect(try await api.listMyBoards().ok.body.json.data.isEmpty)
        #expect(try await api.listMyDecisions().ok.body.json.data.items.isEmpty == false)
    }

    @Test("a body that does not match the contract fails")
    func wrongBody() async {
        let api = FixtureAPI(replacing: [Operations.ListMyBoards.id: Data("{}".utf8)]).client

        await #expect(throws: (any Error).self) {
            _ = try await api.listMyBoards().ok.body.json
        }
    }

    @Test("an unreachable operation fails as if the device were offline, and only that one")
    func unreachable() async throws {
        let api = FixtureAPI(unreachable: [Operations.GetMe.id]).client

        await #expect(throws: (any Error).self) { _ = try await api.getMe() }
        do {
            _ = try await api.getMe()
        } catch {
            #expect(SignInError(classifying: error) == .network)
        }
        #expect(try await api.listMyBoards().ok.body.json.data.isEmpty == false)
    }

    @Test("the locked plan answers me for a person without the Organization plan")
    func lockedPlan() async throws {
        let api = FixtureAPI(replacing: try FixtureAPI.lockedPlan).client
        let me = try await api.getMe().ok.body.json.data
        let fixture = try await FixtureAPI().client.getMe().ok.body.json.data

        #expect(me.appUnlocked == false)
        #expect(fixture.appUnlocked)
        #expect(me.user.id == fixture.user.id)
    }

    @Test("throws for an operation with no fixture")
    func missingFixture() {
        #expect(throws: (any Error).self) { try FixtureAPI.fixture(named: "noSuchOperation") }
    }

    @MainActor
    @Test("a view model loads from the fixtures through the protocol")
    func viewModel() async throws {
        let model = ExampleViewModel(api: FixtureAPI().client)

        try await model.load()

        #expect(model.titles.first == "Add a sign-in screen")
    }
}
