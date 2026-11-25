import Foundation
import HTTPTypes
import Testing

@testable import StrideKit

/// What the client reads beyond the shared fixtures: errors and headers.
struct ResponseDecodingTests {
    @Test("an unknown error code decodes without failing")
    func unknownErrorCode() async throws {
        let transport = StubTransport(
            status: .conflict,
            json: """
                {
                  "error": "brand_new_code",
                  "message": "Review it again.",
                  "review": {"task_id": 1, "identifier": "W1", "review_status": "brand_new_status"}
                }
                """
        )

        let conflict = try await StrideClient.make(transport: transport)
            .requestMyReviewChanges(path: .init(taskId: 1), body: .json(.init(notes: "EXAMPLE")))
            .conflict.body.json

        #expect(conflict.error.value1 == nil)
        #expect(conflict.error.value2 == "brand_new_code")
        #expect(conflict.message == "Review it again.")
    }

    @Test("a cache policy the contract does not list is accepted")
    func unknownCachePolicy() async throws {
        let transport = StubTransport(headers: [.cacheControl: "private, max-age=5"], json: #"{"data": []}"#)

        let response = try await StrideClient.make(transport: transport).listMyBoards().ok

        #expect(response.headers.cacheControl == "private, max-age=5")
    }

    @Test("a signing version this app does not know is refused")
    func unknownSigningVersion() async throws {
        let data = try FixtureChange.body(of: Operations.CreateMyReviewApprovalChallenge.id) { body in
            var challenge = body["data"] as? [String: Any] ?? [:]
            challenge["signing_version"] = "stride-approval-v2"
            body["data"] = challenge
        }
        let api = FixtureAPI(replacing: [Operations.CreateMyReviewApprovalChallenge.id: data]).client

        await #expect(throws: (any Error).self) {
            try await api.createMyReviewApprovalChallenge(
                path: .init(taskId: 1),
                body: .json(.init(reviewFingerprint: "EXAMPLE"))
            ).created.body.json
        }
    }
}
