import Foundation
import Testing

@testable import StrideKit

struct FixtureDecodingTests {
    private static let fixtureNames = ((try? FileManager.default.contentsOfDirectory(
        at: FixtureAPI.directory,
        includingPropertiesForKeys: nil
    )) ?? [])
    .filter { $0.pathExtension == "json" }
    .map { $0.deletingPathExtension().lastPathComponent }
    .sorted()

    /// Decodes through the generated client and encodes the result again, so a
    /// value the generated types drop or change fails, not only one they refuse.
    @Test("every shared fixture decodes with the generated types", arguments: fixtureNames)
    func everyFixtureDecodes(name: String) async throws {
        let call = try #require(FixtureOperations.calls[name], "\(name).json has no operation that decodes it")

        let decoded = try await call(FixtureAPI().client)

        #expect(try values(encoding: decoded) == values(FixtureAPI.fixture(named: name)))
    }

    @Test("the fixtures and the operations that decode them match")
    func fixturesMatchOperations() {
        #expect(Self.fixtureNames == FixtureOperations.calls.keys.sorted())
    }

    @Test("an unknown enum value decodes without failing")
    func unknownEnumValue() async throws {
        let item = try await firstDecision { item in
            item["kind"] = "brand_new_kind"
            item["actions"] = ["brand_new_action"]
        }

        #expect(item.kind.value1 == nil)
        #expect(item.kind.value2 == "brand_new_kind")
        #expect(item.actions.map(\.value1) == [nil])
        #expect(item.actions.map(\.value2) == ["brand_new_action"])
    }

    @Test("a known enum value decodes to its case")
    func knownEnumValue() async throws {
        let item = try await firstDecision { _ in }

        #expect(item.kind.value1 == .review)
    }

    @Test("details of an unknown shape decode without failing")
    func unknownDetails() async throws {
        let item = try await firstDecision { $0["details"] = ["brand_new_key": 1] }

        #expect(item.kind.value1 == .review)
    }

    @Test("an empty decisions list decodes")
    func emptyDecisions() async throws {
        let data = try FixtureChange.body(of: Operations.ListMyDecisions.id) { body in
            var page = body["data"] as? [String: Any] ?? [:]
            page["items"] = [Any]()
            body["data"] = page
        }
        let api = FixtureAPI(replacing: [Operations.ListMyDecisions.id: data]).client

        #expect(try await api.listMyDecisions().ok.body.json.data.items.isEmpty)
    }

    @Test("an unknown field is ignored")
    func unknownField() async throws {
        let item = try await firstDecision { $0["brand_new_field"] = ["nested": true] }

        #expect(item.kind.value1 == .review)
    }

    @Test(
        "reads an ISO 8601 date in any form the API sends",
        arguments: [
            ("2026-11-25T15:00:00Z", 0.0),
            ("2026-11-25T10:00:00-05:00", 0.0),
            ("2026-11-25T15:00:00.250Z", 0.25),
            ("2026-11-25T15:00:00.250000Z", 0.25),
            ("2026-11-25T16:30:00.250000+01:30", 0.25)
        ]
    )
    func dates(text: String, fraction: Double) async throws {
        let item = try await firstDecision { $0["since"] = text }

        let since = try #require(item.since)
        let expected = Date(timeIntervalSince1970: 1_795_618_800 + fraction)
        #expect(abs(since.timeIntervalSince(expected)) < 0.001)
    }

    @Test("refuses a date with no offset")
    func dateWithoutOffset() async {
        await #expect(throws: (any Error).self) {
            try await firstDecision { $0["since"] = "2026-11-25T15:00:00" }
        }
    }

    @Test("a null optional field decodes to nil")
    func nullOptionalFields() async throws {
        let item = try await firstDecision { item in
            item["task_id"] = NSNull()
            item["since"] = NSNull()
        }
        let data = try FixtureChange.firstItem(of: Operations.ListMyBoards.id) { $0["workspace"] = NSNull() }
        let api = FixtureAPI(replacing: [Operations.ListMyBoards.id: data]).client
        let board = try #require(try await api.listMyBoards().ok.body.json.data.first)

        #expect(item.taskId == nil)
        #expect(item.since == nil)
        #expect(board.workspace == nil)
    }

    @Test("an optional object decodes when it is there")
    func presentOptionalObject() async throws {
        let board = try #require(try await FixtureAPI().client.listMyBoards().ok.body.json.data.first)

        #expect(board.workspace?.slug == "engineering")
    }

    @Test(
        "an error body decodes whatever its documentation is",
        arguments: [#""a link""#, #"["a", "b"]"#, #"{"a": "b"}"#]
    )
    func errorDocumentation(documentation: String) throws {
        let data = Data(#"{"error": "Not found", "documentation": \#(documentation)}"#.utf8)

        let error = try JSONDecoder().decode(Components.Schemas._Error.self, from: data)

        #expect(error.error == "Not found")
    }

    private func firstDecision(
        changing change: (inout [String: Any]) -> Void
    ) async throws -> Components.Schemas.DecisionItem {
        let data = try FixtureChange.firstItem(of: Operations.ListMyDecisions.id, change)
        let api = FixtureAPI(replacing: [Operations.ListMyDecisions.id: data]).client

        return try #require(try await api.listMyDecisions().ok.body.json.data.items.first)
    }

    /// The JSON the value encodes to, with dates written as the client writes them.
    private func values(encoding value: any Encodable) throws -> NSObject? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(StrideDateTranscoder().encode(date))
        }
        return try values(encoder.encode(value))
    }

    /// Leaves out null keys: the generated types read a null and a missing key as
    /// the same nil, and write neither.
    private func values(_ data: Data) throws -> NSObject? {
        withoutNulls(try JSONSerialization.jsonObject(with: data)) as? NSObject
    }

    private func withoutNulls(_ value: Any) -> Any {
        switch value {
        case let object as [String: Any]:
            object.filter { !($0.value is NSNull) }.mapValues(withoutNulls)
        case let array as [Any]:
            array.map(withoutNulls)
        default:
            value
        }
    }
}
