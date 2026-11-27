import Foundation
import os
import Testing

@testable import Stride
@testable import StrideKit

/// What the review screen shows of one review: its sections in the design's
/// order, its files flagged first, what it shows offline, and the 409 states.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ReviewModelTests {
    private nonisolated static let fetched = Date(timeIntervalSince1970: 1_795_000_000)

    private static func model(_ data: Data? = nil, statuses: [String: Int] = [:]) -> ReviewModel {
        let replacements = data.map { [Operations.GetMyReview.id: $0] } ?? [:]
        return ReviewModel(taskID: 4812, api: FixtureAPI(replacing: replacements, statuses: statuses).client)
    }

    private static func loaded(_ data: Data? = nil) async throws -> ReviewContent {
        let model = model(data)
        await model.load()
        #expect(model.state == .review)
        return try #require(model.content)
    }

    @Test("shows the header, the summary and the sections from the server")
    func header() async throws {
        let content = try await Self.loaded()

        #expect(content.identifier == "W101")
        #expect(content.title == "Add a sign-in screen")
        #expect(content.priority == .high)
        #expect(content.holdsUp == ["W102", "W103"])
        #expect(content.agent?.name == "Claude")
        #expect(content.timeSpent == .seconds(95 * 60))
        #expect(content.goal == "G11 Ship the first app build")
        #expect(content.summary == "Adds the sign-in screen and its view model, with tests for both themes.")
        #expect(content.pitfalls == Verdict(section: .pitfalls, state: .passed))
        #expect(content.checks == .allPassed)
        #expect(content.securityFindings == ReviewSeverityCounts(critical: 0, important: 0, minor: 1))
        #expect(content.holdsUpLabel(in: Self.en).map(Self.english) == "holds up W102, W103")
        let details = try #require(content.details(in: Self.en))
        #expect(details.hasPrefix("Claude · "))
        #expect(details.contains("35"))
        #expect(details.hasSuffix(" · G11 Ship the first app build"))
        #expect(content.approvableHere)
        #expect(content.tooLargeHere == false)
    }

    @Test("shows 3 of 4 passed with the failed note")
    func threeOfFourPassed() async throws {
        let data = try DecisionFixtures.reviewData { review in
            var verdicts = review["verdicts"] as? [[String: Any]] ?? []
            verdicts[4]["status"] = "passed"
            review["verdicts"] = verdicts
        }
        let content = try await Self.loaded(data)

        #expect(content.tiles.map(\.verdict.section) == [.acceptanceCriteria, .testingStrategy, .patterns, .securityConsiderations])
        #expect(content.passed == 3)
        #expect(content.tiles.count == 4)
        let failed = try #require(content.tiles.first { $0.verdict.state == .failed })
        #expect(failed.verdict.section == .patterns)
        #expect(failed.note == "One view model reads the store directly.")
        #expect(content.tiles.filter { $0.verdict.state != .failed }.allSatisfy { $0.note == nil })
        let english = Self.english(.reviewPassed(passed: String(content.passed), count: content.tiles.count))
        #expect(english == "3 of 4 passed")
        // The verdicts come before the files, as the design orders them.
        let verdicts = try #require(content.sections.firstIndex(of: .verdicts))
        let files = try #require(content.sections.firstIndex(of: .files))
        #expect(verdicts < files)
    }

    @Test("a section not assessed is a tile that did not pass, and a passed note is not shown")
    func notAssessed() async throws {
        let data = try DecisionFixtures.reviewData { review in
            var verdicts = review["verdicts"] as? [[String: Any]] ?? []
            verdicts[0]["note"] = "Every criterion has a test."
            review["verdicts"] = verdicts
        }
        let content = try await Self.loaded(data)

        #expect(content.passed == 2)
        #expect(content.tiles.last?.verdict.state == .notAssessed)
        #expect(content.tiles.first?.note == nil)
    }

    @Test("a review with no verdicts shows no tiles")
    func noVerdicts() async throws {
        let content = try await Self.loaded(try DecisionFixtures.reviewData { $0["verdicts"] = [] })

        #expect(content.tiles.isEmpty)
        #expect(content.pitfalls == nil)
    }

    @Test("a failed note in German is kept as the server sent it")
    func germanNote() async throws {
        let note = "Ein View-Model liest den Speicher direkt – Größe prüfen."
        let data = try DecisionFixtures.reviewData { review in
            var verdicts = review["verdicts"] as? [[String: Any]] ?? []
            verdicts[2]["note"] = note
            review["verdicts"] = verdicts
        }
        let content = try await Self.loaded(data)

        #expect(content.tiles[2].note == note)
    }

    @Test("verdicts show before the checks and the files, and an empty section is left out")
    func sectionOrder() async throws {
        let content = try await Self.loaded()
        #expect(content.sections == [.summary, .verdicts, .checks, .files])

        let bare = try await Self.loaded(try DecisionFixtures.reviewData { review in
            review["summary"] = NSNull()
            review["verdicts"] = []
            review["files"] = []
        })
        #expect(bare.sections == [.checks])
    }

    @Test("the acceptance tile counts the criteria met, and only the acceptance tile")
    func acceptanceCount() async throws {
        let content = try await Self.loaded()
        let acceptance = try #require(content.tiles.first)
        #expect(acceptance.verdict.section == .acceptanceCriteria)
        #expect(acceptance.criteria == ReviewCriteriaCount(met: 2, count: 2))
        #expect(Self.english(try #require(acceptance.criteria).text) == "2/2")
        #expect(acceptance.reading(in: Self.en) == "Acceptance passed, 2 of 2 criteria met")
        #expect(content.tiles.dropFirst().allSatisfy { $0.criteria == nil })

        let oneMet = try await Self.loaded(try DecisionFixtures.reviewData { review in
            var criteria = review["acceptance_criteria"] as? [[String: Any]] ?? []
            criteria[1]["status"] = "not_met"
            review["acceptance_criteria"] = criteria
        })
        #expect(oneMet.tiles.first?.criteria == ReviewCriteriaCount(met: 1, count: 2))

        let unrated = try await Self.loaded(try DecisionFixtures.reviewData { review in
            review["acceptance_criteria"] = [["criterion": "Signs in", "status": NSNull(), "evidence": NSNull()]]
        })
        #expect(unrated.tiles.first?.criteria == nil)
    }

    @Test("the project checks row says all passed, how many were not met, or not reported")
    func checksResults() async throws {
        let passed = try await Self.loaded()
        #expect(passed.checksResult(in: Self.en) == ReviewResult(text: "All passed", tone: .stDone))

        let notMet = try await Self.loaded(try DecisionFixtures.reviewData { review in
            review["project_checks"] = ["met": 3, "not_met": 2, "not_applicable": 0]
        })
        #expect(notMet.checksResult(in: Self.en) == ReviewResult(text: "2 not met", tone: .stBlocked))

        // A single check not met is not all passed, however many were met.
        let oneNotMet = try await Self.loaded(try DecisionFixtures.reviewData { review in
            review["project_checks"] = ["met": 5, "not_met": 1, "not_applicable": 0]
        })
        #expect(oneNotMet.checksResult(in: Self.en) == ReviewResult(text: "1 not met", tone: .stBlocked))

        let none = try await Self.loaded(try DecisionFixtures.reviewData { review in
            review["project_checks"] = ["met": 0, "not_met": 0, "not_applicable": 4]
        })
        #expect(none.checksResult(in: Self.en).tone == .ink2)
        #expect(none.checksResult(in: Self.en).text == Self.english(.nowAttemptNotReported))
    }

    @Test("the pitfalls pill says the verdict, not the section's name again")
    func pitfallsText() async throws {
        let passed = try await Self.loaded()
        #expect(passed.pitfallsText(in: Self.en) == "Passed")

        for (status, word) in [("failed", "Failed"), ("not_assessed", "Not assessed")] {
            let content = try await Self.loaded(try DecisionFixtures.reviewData { review in
                var verdicts = review["verdicts"] as? [[String: Any]] ?? []
                verdicts[3]["status"] = status
                review["verdicts"] = verdicts
            })
            #expect(content.pitfallsText(in: Self.en) == word)
        }

        let none = try await Self.loaded(try DecisionFixtures.reviewData { $0["verdicts"] = [] })
        #expect(none.pitfallsText(in: Self.en) == nil)
    }

    @Test("the security row counts each severity and is red only for critical or important")
    func securityResults() async throws {
        let minor = try await Self.loaded()
        #expect(minor.securityResult(in: Self.en) == ReviewResult(text: "1 minor", tone: .stDoing))

        let mixed = try await Self.loaded(try DecisionFixtures.reviewData { review in
            review["security_findings"] = ["critical": 1, "important": 0, "minor": 2]
        })
        #expect(mixed.securityResult(in: Self.en) == ReviewResult(text: "1 critical · 2 minor", tone: .stBlocked))

        // An important finding with no critical one is still red.
        let important = try await Self.loaded(try DecisionFixtures.reviewData { review in
            review["security_findings"] = ["critical": 0, "important": 1, "minor": 1]
        })
        #expect(important.securityResult(in: Self.en) == ReviewResult(text: "1 important · 1 minor", tone: .stBlocked))

        let none = try await Self.loaded(try DecisionFixtures.reviewData { review in
            review["security_findings"] = ["critical": 0, "important": 0, "minor": 0]
        })
        #expect(none.securityResult(in: Self.en) == ReviewResult(text: "No findings", tone: .stDone))
    }

    @Test("the exploratory row shows its findings, none, or the notes on the web")
    func exploratoryResults() async throws {
        let onWeb = try await Self.loaded()
        #expect(onWeb.exploratoryResult(in: Self.en) == ReviewResult(text: "See notes on the web", tone: .ink2))

        let none = try await Self.loaded(try DecisionFixtures.reviewData { $0["exploratory"] = ["count": 0, "note": NSNull()] })
        #expect(none.exploratoryResult(in: Self.en) == ReviewResult(text: "No findings", tone: .stDone))

        let two = try await Self.loaded(try DecisionFixtures.reviewData { $0["exploratory"] = ["count": 2, "note": NSNull()] })
        #expect(two.exploratoryResult(in: Self.en) == ReviewResult(text: "2 findings", tone: .stDoing))
    }

    @Test("a review that holds nothing up shows no holds-up pill")
    func holdsNothingUp() async throws {
        let content = try await Self.loaded(try DecisionFixtures.reviewData { $0["holds_up"] = [] })
        #expect(content.holdsUpLabel(in: Self.en) == nil)
    }

    @Test("each file row reads its name, folder and lines in words")
    func fileReadings() async throws {
        let content = try await Self.loaded()

        #expect(content.files.map { $0.reading(in: Self.en) } == [
            "flagged, SignInView.swift in mobile/ios/Stride/SignIn, 120 lines added, 4 lines removed",
            "SignInViewModelTests.swift in mobile/ios/StrideTests, 64 lines added, 0 lines removed",
            "Logo.png in mobile/ios/Stride/Assets.xcassets",
        ])

        let root = try await Self.loaded(try DecisionFixtures.reviewData { review in
            var files = review["files"] as? [[String: Any]] ?? []
            files[0]["path"] = "README.md"
            files[0]["additions"] = 1
            files[0]["deletions"] = 1
            review["files"] = files
        })
        #expect(root.files[0].reading(in: Self.en) == "flagged, README.md, 1 line added, 1 line removed")
    }

    @Test("orders flagged files first")
    func flaggedFirst() async throws {
        let data = try DecisionFixtures.reviewData { review in
            var files = review["files"] as? [[String: Any]] ?? []
            // The server sends flagged files first; the app keeps them first
            // even when an answer does not.
            files[0]["flagged"] = false
            files[0]["flag_reason"] = NSNull()
            files[2]["flagged"] = true
            files[2]["flag_reason"] = "security"
            review["files"] = files
        }
        let content = try await Self.loaded(data)

        #expect(content.files.map(\.path) == [
            "mobile/ios/Stride/Assets.xcassets/Logo.png",
            "mobile/ios/Stride/SignIn/SignInView.swift",
            "mobile/ios/StrideTests/SignInViewModelTests.swift",
        ])
        #expect(content.files.map(\.isFlagged) == [true, false, false])
        #expect(content.hasFlaggedFiles)
    }

    @Test("a file with no stored diff does not open, and shows no counts")
    func fileWithoutDiff() async throws {
        let content = try await Self.loaded()

        #expect(content.files.map(\.opens) == [true, true, false])
        #expect(content.files[0].additions == 120)
        #expect(content.files[0].deletions == 4)
        #expect(content.files[2].additions == nil)
    }

    @Test("a review with no files shows no file list")
    func noFiles() async throws {
        let content = try await Self.loaded(try DecisionFixtures.reviewData { $0["files"] = [] })

        #expect(content.files.isEmpty)
        #expect(content.hasFlaggedFiles == false)
    }

    @Test("no structured exploratory block shows See notes on the web")
    func exploratoryOnWeb() async throws {
        let content = try await Self.loaded()
        #expect(content.exploratory == .seeNotesOnWeb)
        #expect(Self.english(.reviewSeeNotesOnWeb) == "See notes on the web")

        let counted = try await Self.loaded(try DecisionFixtures.reviewData { review in
            review["exploratory"] = ["count": 2, "note": NSNull()]
        })
        #expect(counted.exploratory == .findings(2))
    }

    @Test("project checks that were not met say how many")
    func checksNotMet() async throws {
        let content = try await Self.loaded(try DecisionFixtures.reviewData { review in
            review["project_checks"] = ["met": 3, "not_met": 2, "not_applicable": 0]
        })
        #expect(content.checks == .notMet(2))

        let none = try await Self.loaded(try DecisionFixtures.reviewData { review in
            review["project_checks"] = ["met": 0, "not_met": 0, "not_applicable": 0]
        })
        #expect(none.checks == .notReported)
    }

    @Test("a change too large for this device says where to approve it")
    func tooLarge() async throws {
        let content = try await Self.loaded(try DecisionFixtures.reviewData { review in
            review["approvable_here"] = false
            review["approvable_here_reason"] = "too_large_for_phone"
        })

        #expect(content.approvableHere == false)
        #expect(content.tooLargeHere)
    }

    @Test("409 already decided shows who decided")
    func alreadyDecided() async throws {
        let model = Self.model()
        await model.load()
        #expect(model.canAct)

        model.show(Self.conflict(.alreadyDecided, status: .approved, by: "Sam Rivera"))

        #expect(model.conflict == .alreadyDecided(by: "Sam Rivera", decision: .approved, at: Self.fetched))
        #expect(model.canAct == false)
        let message = ReviewConflictCopy.message(for: try #require(model.conflict))
        #expect(Self.english(message) == "Sam Rivera approved this.")
        let when = ReviewConflictCopy.when(Self.fetched, relativeTo: Self.fetched.addingTimeInterval(120), in: Self.en)
        #expect(when == "2 minutes ago")
    }

    @Test("two reviewers: the second sees what the first decided, or that someone did")
    func secondReviewer() throws {
        let changes = ReviewConflictState(Self.conflict(.alreadyDecided, status: .changesRequested, by: "Ana Lima"))
        #expect(changes == .alreadyDecided(by: "Ana Lima", decision: .changesRequested, at: Self.fetched))
        #expect(Self.english(ReviewConflictCopy.message(for: changes)) == "Ana Lima requested changes.")

        let unnamed = ReviewConflictState(Self.conflict(.alreadyDecided, status: .rejected, by: nil))
        #expect(Self.english(ReviewConflictCopy.message(for: unnamed)) == "Someone else decided this review.")
    }

    @Test("409 resubmitted asks to reload")
    func resubmitted() async throws {
        let asked = OSAllocatedUnfairLock(initialState: 0)
        let model = ReviewModel(taskID: 4812, api: FixtureAPI(onSend: { id, _ in
            if id == Operations.GetMyReview.id { asked.withLock { $0 += 1 } }
        }).client)
        await model.load()

        model.show(Self.conflict(.resubmitted, status: nil, by: nil))
        #expect(model.conflict == .resubmitted)
        #expect(Self.english(ReviewConflictCopy.message(for: .resubmitted)) == "The agent sent a new version. Reload to review it.")

        await model.reload()

        #expect(model.conflict == nil)
        #expect(model.state == .review)
        #expect(asked.withLock { $0 } == 2)
    }

    @Test("a review that no longer waits on the person says so")
    func unavailable() async {
        let model = Self.model(Data(#"{"error": "Not Found"}"#.utf8), statuses: [Operations.GetMyReview.id: 404])

        await model.load()

        #expect(model.state == .unavailable)
        #expect(model.content == nil)
    }

    @Test("offline reads the cached review, and with nothing saved says so")
    func offline() async throws {
        let container = try TemporaryContainer()
        let cache = Cache(container: container.url, now: { Self.fetched })
        let online = ReviewModel(taskID: 4812, api: FixtureAPI().client, cache: cache, now: { Self.fetched })
        await online.load()
        #expect(online.offlineBanner == nil)

        let unreachable = FixtureAPI(unreachable: [Operations.GetMyReview.id]).client
        let offline = ReviewModel(taskID: 4812, api: unreachable, cache: cache)
        await offline.load()
        #expect(offline.state == .review)
        #expect(offline.content?.identifier == "W101")
        #expect(offline.offlineBanner == OfflineBannerContent(fetchedAt: Self.fetched))
        #expect(offline.canAct == false)

        let other = ReviewModel(taskID: 9999, api: unreachable, cache: cache)
        await other.load()
        #expect(other.state == .nothingSaved)
        withExtendedLifetime(container) {}
    }

    @Test("a refresh error keeps the review shown")
    func refreshErrorKeeps() async {
        let isOffline = OSAllocatedUnfairLock(initialState: false)
        let model = ReviewModel(
            taskID: 4812,
            api: FixtureAPI(isOffline: { isOffline.withLock { $0 } }).client,
            now: { Self.fetched }
        )
        await model.load()

        isOffline.withLock { $0 = true }
        await model.load()

        #expect(model.content?.identifier == "W101")
        #expect(model.lastLoadFailed)
        #expect(model.offlineBanner == OfflineBannerContent(fetchedAt: Self.fetched))
    }

    @Test("the router opens a review from the queue with its own model")
    func routerModel() {
        let router = AppRouter(api: FixtureAPI().client)
        let model = router.reviewModel(for: 4818)

        #expect(model.taskID == 4818)
        #expect(model.state == .loading)
    }

    private static let en = Locale(identifier: "en")

    private static func english(_ resource: LocalizedStringResource) -> String {
        resource.resolved(in: Locale(identifier: "en"))
    }

    private static func conflict(
        _ error: Components.Schemas.ReviewConflict._ErrorPayload.Value1Payload,
        status: Components.Schemas.ReviewState.ReviewStatusPayload.Value1Payload?,
        by name: String?
    ) -> Components.Schemas.ReviewConflict {
        Components.Schemas.ReviewConflict(
            error: .init(value1: error),
            message: "This review has already been decided.",
            review: .init(
                taskId: 4812,
                identifier: "W101",
                reviewStatus: status.map { .init(value1: $0) },
                reviewRequestedAt: fetched,
                reviewedAt: name == nil ? nil : fetched,
                reviewedBy: name
            )
        )
    }
}
