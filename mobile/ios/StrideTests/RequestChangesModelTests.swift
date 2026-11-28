import Foundation
import os
import Testing

@testable import Stride
@testable import StrideKit

/// Request changes on the review screen: the sheet's text and chips, the one
/// resend with the same idempotency key, what each answer shows, and the copy
/// of decision 10.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RequestChangesModelTests {
    private nonisolated static let changesID = Operations.RequestMyReviewChanges.id
    private nonisolated static let reviewID = Operations.GetMyReview.id
    private static let patternsNote = "One view model reads the store directly."

    // MARK: Helpers

    /// A review loaded from `fixtures`, with its Request changes sheet open.
    private static func opened(
        _ fixtures: FixtureAPI,
        cache: Cache? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> (ReviewModel, RequestChangesModel) {
        let model = ReviewModel(taskID: 4812, api: fixtures.client, cache: cache)
        await model.load()
        try #require(model.state == .review, sourceLocation: sourceLocation)
        try #require(model.canRequestChanges, sourceLocation: sourceLocation)
        model.openRequestChanges()
        return (model, try #require(model.changesSheet, sourceLocation: sourceLocation))
    }

    /// A sheet with no review behind it, for the text alone.
    private static func sheet(
        findings: [ReviewFinding] = [],
        agentName: String? = "Claude",
        isOffline: Bool = false
    ) -> RequestChangesModel {
        RequestChangesModel(
            identifier: "W101",
            title: "Add the cache size setting",
            agentName: agentName,
            findings: findings,
            isOffline: { isOffline },
            send: { _ in nil }
        )
    }

    private static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private static func conflictBody() throws -> Data {
        try json([
            "error": "already_decided",
            "message": "This review has already been decided.",
            "review": [
                "task_id": 4812,
                "identifier": "W101",
                "review_status": "changes_requested",
                "review_requested_at": "2026-11-18T09:30:00Z",
                "reviewed_at": "2026-11-18T09:40:00Z",
                "reviewed_by": "Ana Lima",
            ] as [String: Any],
        ])
    }

    /// A request body as JSON, or nil when there was none.
    private static func object(_ body: Data??) throws -> [String: Any] {
        let data = try #require(body ?? nil)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func resolved(_ resource: LocalizedStringResource?, in locale: String = "en") throws -> String {
        try #require(resource).resolved(in: Locale(identifier: locale))
    }

    private static func verdict(_ section: String, _ status: String, _ note: String) -> [String: Any] {
        ["section": section, "status": status, "note": note]
    }

    // MARK: The text

    @Test(
        "Send is disabled until text is entered",
        arguments: ["", "   ", "\n\t\n", "\u{200B}", "\u{0301}", "\u{00A0}\u{2028}", "\u{FEFF}\u{0007}"]
    )
    func sendNeedsText(blank: String) {
        let sheet = Self.sheet()
        #expect(sheet.canSend == false)

        sheet.text = blank
        #expect(sheet.hasText == false)
        #expect(sheet.canSend == false)

        sheet.text = blank + "Fix it" + blank
        #expect(sheet.canSend)
    }

    @Test("notes of up to 10,000 characters can be sent, and longer ones say so")
    func limit() {
        let sheet = Self.sheet()

        sheet.text = String(repeating: "a", count: RequestChangesModel.limit)
        #expect(sheet.isTooLong == false)
        #expect(sheet.canSend)

        // Counted in codepoints, as the server counts them: one emoji is one.
        sheet.text = String(repeating: "a", count: RequestChangesModel.limit - 1) + "👍"
        #expect(sheet.isTooLong == false)

        sheet.text += "b"
        #expect(sheet.isTooLong)
        #expect(sheet.canSend == false)
    }

    @Test("a chip on an empty field inserts the verdict's note alone, once")
    func chipInsertsNote() throws {
        let finding = ReviewFinding(section: .patterns, note: Self.patternsNote)
        let sheet = Self.sheet(findings: [finding])
        #expect(sheet.canAdd(finding))

        sheet.add(finding)
        #expect(sheet.text == Self.patternsNote)
        #expect(sheet.canAdd(finding) == false)

        // A second tap adds nothing.
        sheet.add(finding)
        #expect(sheet.text == Self.patternsNote)
    }

    @Test("a chip inserts the verdict's note")
    func twoChips() {
        let patterns = ReviewFinding(section: .patterns, note: Self.patternsNote)
        let testing = ReviewFinding(section: .testingStrategy, note: "No test covers an empty list.")
        let sheet = Self.sheet(findings: [testing, patterns])
        sheet.text = "Please fix these.\n  "

        sheet.add(testing)
        sheet.add(patterns)

        #expect(sheet.text == "Please fix these.\n\nNo test covers an empty list.\n\n\(Self.patternsNote)")
        #expect(sheet.canAdd(testing) == false)
        #expect(sheet.canAdd(patterns) == false)
    }

    @Test("the chips are the failed verdicts with a note, pitfalls included, in the sections' order")
    func findings() async throws {
        let review = try DecisionFixtures.reviewData { review in
            review["verdicts"] = [
                Self.verdict("security_considerations", "failed", "The token is logged."),
                Self.verdict("pitfalls", "failed", "It queries in the LiveView."),
                Self.verdict("patterns", "failed", "  \n "),
                Self.verdict("acceptance_criteria", "passed", "Met."),
                Self.verdict("testing_strategy", "failed", "No test covers an empty list."),
            ]
        }
        let model = ReviewModel(taskID: 4812, api: FixtureAPI(replacing: [Self.reviewID: review]).client)
        await model.load()
        let content = try #require(model.content)

        #expect(content.findings.map(\.section) == [.testingStrategy, .pitfalls, .securityConsiderations])
        #expect(content.findings.first?.note == "No test covers an empty list.")
    }

    @Test("the footnote says who gets the note, and that the task stays in Review")
    func footnote() throws {
        #expect(
            try Self.resolved(Self.sheet().footnote)
                == "Claude gets this note. The task stays in Review until the changes are picked up."
        )
        #expect(
            try Self.resolved(Self.sheet(agentName: nil).footnote)
                == "The agent gets this note. The task stays in Review until the changes are picked up."
        )
    }

    // MARK: Sending

    @Test("sends and shows Changes requested")
    func sends() async throws {
        let container = try TemporaryContainer()
        let cache = Cache(container: container.url)
        let heard = HeardRequests()
        let (model, sheet) = try await Self.opened(heard.fixtures(), cache: cache)
        let content = try #require(model.content)
        #expect(try await cache.cached(.review(taskID: 4812)) != nil)

        sheet.text = "  Move the member count query into Organizations.\n"
        await sheet.send()

        #expect(model.changesRequested)
        #expect(model.changesSheet == nil)
        #expect(sheet.problem == nil)
        #expect(
            try Self.resolved(model.changesRequestedMessage)
                == "Changes requested. W101 is waiting for Claude to pick up the changes."
        )
        #expect(model.showsDecisionNotice)
        #expect(model.canRequestChanges == false)
        #expect(model.canApprove == false)
        #expect(model.isRequestingChanges == false)

        // The notes, trimmed, with the review_requested_at the screen loaded.
        // Compared as booleans, so a failure never prints them.
        try #require(heard.keys(of: Self.changesID).count == 1)
        let body = try Self.object(heard.bodies(of: Self.changesID).first)
        let sentNotes = body["notes"] as? String == "Move the member count query into Organizations."
        #expect(sentNotes)
        let sentAt = (body["review_requested_at"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
        #expect(sentAt == content.reviewRequestedAt)
        let key = try #require(heard.keys(of: Self.changesID).first ?? nil)
        #expect(UUID(uuidString: key) != nil)

        // Decided here: it is no longer cached, and a refresh asks nothing.
        #expect(try await cache.cached(.review(taskID: 4812)) == nil)
        let asked = heard.operations.count
        await model.load()
        #expect(heard.operations.count == asked)
        #expect(model.changesRequested)
        withExtendedLifetime(container) {}
    }

    @Test("the copy matches decision 10 in German, and without an agent")
    func copy() async throws {
        let (model, sheet) = try await Self.opened(FixtureAPI())
        sheet.text = "Fix it."
        await sheet.send()

        #expect(
            try Self.resolved(model.changesRequestedMessage, in: "de")
                == "Änderungen angefordert. W101 wartet darauf, dass Claude die Änderungen übernimmt."
        )

        let review = try DecisionFixtures.reviewData { review in
            var task = try #require(review["task"] as? [String: Any])
            task["completed_by_agent"] = NSNull()
            review["task"] = task
        }
        let (unnamed, unnamedSheet) = try await Self.opened(FixtureAPI(replacing: [Self.reviewID: review]))
        unnamedSheet.text = "Fix it."
        await unnamedSheet.send()

        #expect(
            try Self.resolved(unnamed.changesRequestedMessage)
                == "Changes requested. W101 is waiting for the agent to pick up the changes."
        )
    }

    @Test("a lost request is sent once more with the same key and body")
    func resendsWithTheSameKey() async throws {
        let heard = HeardRequests()
        let fixtures = heard.fixtures(
            isOffline: { heard.operations.last == Self.changesID && heard.keys(of: Self.changesID).count == 1 }
        )
        let (model, sheet) = try await Self.opened(fixtures)
        sheet.text = "Fix it."

        await sheet.send()

        #expect(model.changesRequested)
        let keys = heard.keys(of: Self.changesID)
        try #require(keys.count == 2)
        #expect(keys[0] != nil && keys[0] == keys[1])
        let sent = heard.bodies(of: Self.changesID)
        let sameBody = sent.count == 2 && sent[0] != nil && sent[0] == sent[1]
        #expect(sameBody)
    }

    @Test("two lost requests say it failed and keep the notes, and Send again uses a new key")
    func twoLost() async throws {
        let heard = HeardRequests()
        let fixtures = heard.fixtures(
            isOffline: { heard.operations.last == Self.changesID && heard.keys(of: Self.changesID).count <= 2 }
        )
        let (model, sheet) = try await Self.opened(fixtures)
        sheet.text = "Fix it."

        await sheet.send()
        #expect(sheet.problem == .failed)
        #expect(sheet.text == "Fix it.")
        #expect(model.changesSheet === sheet)
        #expect(model.changesRequested == false)
        #expect(sheet.canSend)

        await sheet.send()
        #expect(model.changesRequested)
        let keys = heard.keys(of: Self.changesID)
        try #require(keys.count == 3)
        #expect(keys[2] != keys[0])
    }

    @Test(
        "a refusal says why and keeps the sheet open",
        arguments: [(403, RequestChangesProblem.notAllowed), (422, .refused), (500, .failed)]
    )
    func refused(status: Int, problem: RequestChangesProblem) async throws {
        let body = switch status {
        case 403: try Self.json(["error": "plan_required", "feature": "mobile_app", "message": "Upgrade to use the app."])
        case 422: try Self.json(["errors": ["notes": ["can't be blank"]]])
        default: try Self.json(["error": "refused"])
        }
        let (model, sheet) = try await Self.opened(
            FixtureAPI(replacing: [Self.changesID: body], statuses: [Self.changesID: status])
        )
        sheet.text = "Fix it."

        await sheet.send()

        #expect(sheet.problem == problem)
        #expect(model.changesSheet === sheet)
        #expect(model.changesRequested == false)
        #expect(model.canRequestChanges)
    }

    @Test("a 409 shows Already decided")
    func alreadyDecided() async throws {
        let (model, sheet) = try await Self.opened(
            FixtureAPI(replacing: [Self.changesID: try Self.conflictBody()], statuses: [Self.changesID: 409])
        )
        sheet.text = "Fix it."

        await sheet.send()

        guard case .alreadyDecided(let name, let decision, _) = model.conflict else {
            Issue.record("no Already decided: \(String(describing: model.conflict))")
            return
        }
        #expect(name == "Ana Lima")
        #expect(decision == .changesRequested)
        #expect(model.changesSheet == nil)
        #expect(model.changesRequested == false)
        #expect(model.canRequestChanges == false)
        #expect(model.canApprove == false)
    }

    @Test("a 404 says the review is gone and closes the sheet")
    func gone() async throws {
        let (model, sheet) = try await Self.opened(
            FixtureAPI(replacing: [Self.changesID: try Self.json(["error": "Not Found"])], statuses: [Self.changesID: 404])
        )
        sheet.text = "Fix it."

        await sheet.send()

        #expect(model.state == .unavailable)
        #expect(model.changesSheet == nil)
        #expect(model.changesRequested == false)
    }

    @Test("offline, Send is off and nothing is sent")
    func offline() async throws {
        let heard = HeardRequests()
        let isOffline = OSAllocatedUnfairLock(initialState: false)
        let (model, sheet) = try await Self.opened(heard.fixtures(isOffline: { isOffline.withLock { $0 } }))
        sheet.text = "Fix it."
        isOffline.withLock { $0 = true }
        await model.load()

        #expect(sheet.isOffline)
        #expect(sheet.canSend == false)
        #expect(model.canRequestChanges == false)
        await sheet.send()

        #expect(heard.keys(of: Self.changesID).isEmpty)
        #expect(model.changesRequested == false)
    }

    @Test("while the notes are on their way, neither decision can start")
    func busy() async throws {
        let gate = RequestGate()
        let fixtures = FixtureAPI(hold: { id in if id == Self.changesID { await gate.wait() } })
        let api = fixtures.client
        let model = ReviewModel(
            taskID: 4812, api: api, approvals: ApproveFlow(api: api, signer: StubApprovalSigning.match)
        )
        await model.load()
        try #require(model.canApprove)
        model.openRequestChanges()
        let sheet = try #require(model.changesSheet)
        sheet.text = "Fix it."

        let sending = Task { await sheet.send() }
        await gate.untilHeld()
        #expect(sheet.isSending)
        #expect(sheet.canSend == false)
        #expect(model.isRequestingChanges)
        #expect(model.canApprove == false)
        #expect(model.canRequestChanges == false)
        gate.open()
        await sending.value

        #expect(model.changesRequested)
        #expect(model.canApprove == false)
    }

    @Test(
        "a load on its way when the changes land neither hides the toast nor caches the review again",
        arguments: [404, nil] as [Int?]
    )
    func loadOnItsWay(status: Int?) async throws {
        let container = try TemporaryContainer()
        let cache = Cache(container: container.url)
        let heard = HeardRequests()
        let gate = RequestGate()
        let fixtures = heard.fixtures(
            status: { id in id == Self.reviewID && !heard.keys(of: Self.changesID).isEmpty ? status : nil },
            hold: { id in
                if id == Self.reviewID, heard.operations.filter({ $0 == Self.reviewID }).count == 2 { await gate.wait() }
            }
        )
        let (model, sheet) = try await Self.opened(fixtures, cache: cache)
        sheet.text = "Fix it."

        let refresh = Task { await model.load() }
        await gate.untilHeld()
        await sheet.send()
        gate.open()
        await refresh.value

        #expect(model.state == .review)
        #expect(model.changesRequested)
        #expect(model.isOffline == false)
        #expect(try await cache.cached(.review(taskID: 4812)) == nil)
        withExtendedLifetime(container) {}
    }
}
