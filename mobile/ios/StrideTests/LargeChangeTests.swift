import Foundation
import Testing

@testable import Stride
@testable import StrideKit

/// A change too large to approve on this device: the server's
/// `approvable_here` alone decides, the notice shows the change's size from
/// the response, and Approve on tablet or web opens the web's Review page,
/// while Request changes stays available.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LargeChangeTests {
    private nonisolated static let challengeID = Operations.CreateMyReviewApprovalChallenge.id
    private nonisolated static let reviewID = Operations.GetMyReview.id
    private static let en = Locale(identifier: "en")

    /// The review fixture with its size and `approvable_here` set.
    private static func review(
        approvableHere: Bool,
        files: Int,
        filesUnknown: Bool = false,
        changedLines: Int
    ) throws -> Data {
        try DecisionFixtures.reviewData { review in
            review["approvable_here"] = approvableHere
            review["approvable_here_reason"] = approvableHere ? NSNull() : "too_large_for_phone"
            review["size"] = [
                "files": files,
                "files_unknown": filesUnknown,
                "changed_lines": changedLines,
                "truncated": false,
                "large_change": !approvableHere,
            ] as [String: Any]
        }
    }

    /// A loaded model that answers the review with `data`, with a signer that
    /// matches the face.
    private static func loaded(
        _ fixtures: FixtureAPI,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> ReviewModel {
        let api = fixtures.client
        let model = ReviewModel(
            taskID: 4812,
            api: api,
            approvals: ApproveFlow(api: api, signer: StubApprovalSigning.match)
        )
        await model.load()
        try #require(model.state == .review, sourceLocation: sourceLocation)
        return model
    }

    private static func loaded(
        _ data: Data,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> ReviewModel {
        try await loaded(FixtureAPI(replacing: [reviewID: data]), sourceLocation: sourceLocation)
    }

    @Test("approvable_here false shows the banner and web button")
    func notApprovableHere() async throws {
        let model = try await Self.loaded(FixtureAPI(replacing: try FixtureAPI.largeReview))

        let size = try #require(model.largeChange, "no notice for a change no phone may approve")
        #expect(size == ReviewChangeSize(files: 14, changedLines: 652))
        #expect(size.text(in: Self.en) == "14 files and 652 changed lines")
        #expect(model.approvableHere == false)
        #expect(model.canApprove == false)
        #expect(model.canOpenOnWeb)
        #expect(model.webReviewURL == StrideWeb.review(taskID: 4812))
        #expect(model.canRequestChanges, "Request changes went away with Approve")
    }

    /// The server decides, so a small change it will not let a phone approve
    /// still shows the notice with its own counts.
    @Test("the counts come from the response, not a limit in the app")
    func countsFromTheResponse() async throws {
        let model = try await Self.loaded(try Self.review(approvableHere: false, files: 2, changedLines: 1))

        let size = try #require(model.largeChange)
        #expect(size.text(in: Self.en) == "2 files and 1 changed line")
        #expect(model.canApprove == false)
    }

    @Test(
        "approvable_here true keeps Approve",
        arguments: [
            (files: 3, lines: 188),
            // Exactly at the phone limits.
            (files: 10, lines: 500),
            // Past them: the app never works the limit out itself.
            (files: 11, lines: 652),
        ]
    )
    func approvableHere(size: (files: Int, lines: Int)) async throws {
        let model = try await Self.loaded(try Self.review(approvableHere: true, files: size.files, changedLines: size.lines))

        #expect(model.approvableHere)
        #expect(model.largeChange == nil)
        #expect(model.canApprove)
        #expect(model.canRequestChanges)
    }

    @Test("a server refusal still shows the guard")
    func refusedByTheServer() async throws {
        let heard = HeardRequests()
        let body = try JSONSerialization.data(withJSONObject: [
            "error": "too_large_for_phone",
            "message": "Approve it on a tablet or on the web.",
            "size": ["files": 14, "files_unknown": false, "changed_lines": 652, "truncated": false] as [String: Any],
            "limits": ["max_files": 10, "max_changed_lines": 500],
        ])
        // The review still says approvable_here true, as one loaded before
        // the change grew would.
        let model = try await Self.loaded(
            heard.fixtures(
                replacing: [
                    Self.reviewID: try Self.review(approvableHere: true, files: 3, changedLines: 188),
                    Self.challengeID: body,
                ],
                statuses: [Self.challengeID: 422]
            )
        )
        try #require(model.canApprove)

        await model.approve(web: StubWebAuthenticator(outcome: .allow))

        #expect(heard.operations.last == Self.reviewID, "the review was not loaded again")
        #expect(heard.operations.contains(Operations.ApproveMyReview.id) == false)
        #expect(model.approvableHere == false)
        #expect(model.canApprove == false)
        #expect(model.largeChange == ReviewChangeSize(files: 3, changedLines: 188))
        #expect(model.canOpenOnWeb)
        #expect(model.canRequestChanges)
        #expect(model.approveProblem == nil)
    }

    /// A 403 is not the size guard: it says the person may not approve, and
    /// Approve stays where it was.
    @Test("a 403 on approve despite approvable_here true is not the guard")
    func forbidden() async throws {
        let body = try JSONSerialization.data(
            withJSONObject: ["error": "plan_required", "feature": "mobile_app", "message": "Upgrade to use the app."]
        )
        let model = try await Self.loaded(
            HeardRequests().fixtures(replacing: [Self.challengeID: body], statuses: [Self.challengeID: 403])
        )

        await model.approve(web: StubWebAuthenticator(outcome: .allow))

        #expect(model.largeChange == nil)
        #expect(model.approvableHere)
        #expect(model.approveProblem == .notAllowed)
    }

    @Test("files the server could not count show the lines alone")
    func filesUnknown() async throws {
        let model = try await Self.loaded(
            try Self.review(approvableHere: false, files: 0, filesUnknown: true, changedLines: 652)
        )

        let size = try #require(model.largeChange)
        #expect(size.files == nil)
        #expect(size.text(in: Self.en) == "652 changed lines")
    }

    @Test("the size reads in the person's language")
    func german() {
        let size = ReviewChangeSize(files: 14, changedLines: 652)

        #expect(size.text(in: Locale(identifier: "de")) == "14 Dateien und 652 geänderte Zeilen")
    }

    @Test("a negative count from the server shows as nothing")
    func negativeCounts() {
        #expect(ReviewChangeSize(files: -1, changedLines: -5) == ReviewChangeSize(files: 0, changedLines: 0))
    }

    /// Once decided here, the web has nothing left to approve.
    @Test("the web button turns off once changes are requested")
    func webButtonAfterADecision() async throws {
        let model = try await Self.loaded(FixtureAPI(replacing: try FixtureAPI.largeReview))
        model.openRequestChanges()
        let sheet = try #require(model.changesSheet)
        sheet.text = "Split this change in two."

        await sheet.send()

        #expect(model.isDecided)
        #expect(model.canOpenOnWeb == false)
    }

    @Test("the web review is only ever the Stride server's /review page")
    func webReviewURL() async throws {
        let model = try await Self.loaded(FixtureAPI(replacing: try FixtureAPI.largeReview))
        let url = try #require(model.webReviewURL)

        #expect(StrideWeb.isStridePage(url))
        #expect(url.path() == "/review")
        #expect(url.query() == "task=4812")
    }
}
