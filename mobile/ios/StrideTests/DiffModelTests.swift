import Foundation
import os
import Testing

@testable import Stride
@testable import StrideKit

/// What the file screen shows of one file: its lines and notes, its header,
/// the files it pages through, and the 404, 409 and offline states.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DiffModelTests {
    private nonisolated static let fetched = Date(timeIntervalSince1970: 1_795_000_000)
    private static let en = Locale(identifier: "en")

    @Test("places a note at its line")
    func noteAtItsLine() async throws {
        let content = try await DiffFixtures.loaded()

        let kinds = content.rows.map(\.kind)
        let note = try #require(kinds.firstIndex { if case .note = $0 { true } else { false } })
        try #require(note > 0, "the diff starts with a note")
        guard case .line(let above) = kinds[note - 1], case .note(let placed) = kinds[note] else {
            Issue.record("A note is not under a line")
            return
        }
        #expect(above.kind == .added)
        #expect(above.newNumber == 3)
        #expect(placed.reviewer == .security)
        #expect(placed.text == "Interpolates input into a greeting without a length limit.")
        #expect(kinds.count(where: { if case .note = $0 { true } else { false } }) == 1)
        #expect(content.rows.map(\.id) == Array(0..<content.rows.count))

        let label = placed.label(in: Self.en)
        #expect(String(label.characters) == "Security reviewer: Interpolates input into a greeting without a length limit.")
        let bold = label.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
        #expect(bold.map { String(label[$0.range].characters) } == ["Security reviewer"])
    }

    @Test("a note on the whole file or on a line the diff lacks goes above the diff")
    func fileNotes() async throws {
        let data = try DiffFixtures.fileData { file in
            var notes = try #require(file["notes"] as? [[String: Any]])
            notes.append(["line": 99, "anchored": true, "severity": "minor", "category": "testing", "description": "Line 99 is untested."])
            notes.append(["line": 2, "anchored": true, "severity": "minor", "category": "pattern", "description": ""])
            file["notes"] = notes
        }
        let content = try await DiffFixtures.loaded(data)

        #expect(content.fileNotes.map(\.text) == ["The file has no tests yet.", "Line 99 is untested."])
        #expect(content.fileNotes.map(\.reviewer) == [.other, .testing])
        // A note with no explanation has nothing to show.
        #expect(content.rows.count == 7)
        // Each note keeps its own identity, above the diff or under a line.
        let inline = content.rows.compactMap { if case .note(let note) = $0.kind { note.id } else { nil } }
        let ids = content.fileNotes.map(\.id) + inline
        #expect(Set(ids).count == ids.count, "note ids \(ids)")
    }

    @Test("shows the header from the server: counts, language, flag and path")
    func header() async throws {
        let content = try await DiffFixtures.loaded()

        #expect(content.path == "lib/example/greeting.ex")
        #expect(content.name == "greeting.ex")
        #expect(content.language == .elixir)
        #expect(content.language.name(in: Self.en) == "Elixir")
        #expect(content.isFlagged)
        #expect(content.additions == 3)
        #expect(content.deletions == 1)
        #expect(content.countsReading(in: Self.en) == "3 lines added and 1 line removed")
        #expect(content.pathReading(in: Self.en) == "greeting.ex in lib/example")
        #expect(FilePlace.reading(of: "README.md", in: Self.en) == "README.md")
        #expect(content.isTruncated == false)
    }

    @Test("lines keep the server's highlighting, numbers and kinds")
    func highlighting() async throws {
        let content = try await DiffFixtures.loaded()
        let lines = content.rows.compactMap { if case .line(let line) = $0.kind { line } else { nil } }

        try #require(lines.map(\.kind) == [.hunk, .context, .removed, .added, .added, .added])
        #expect(lines[2].oldNumber == 2)
        #expect(lines[2].newNumber == nil)
        #expect(lines[1].spans.map(\.kind) == [.keyword, .plain, .module, .plain, .keyword])
        #expect(lines[4].text == "  def hello(name), do: \"Hello, #{name}\"")
        #expect(lines[3].reading(in: Self.en) == "Added, line 2")
        #expect(lines[2].reading(in: Self.en) == "Removed, line 2")
    }

    @Test("plain text when the language has no lexer")
    func plainText() async throws {
        let data = try DiffFixtures.fileData { file in
            file["language"] = "plain"
            file["lines"] = [["kind": "add", "old": NSNull(), "new": 1, "spans": [["class": "plain", "text": "fn main() {}"]]]]
        }
        let content = try await DiffFixtures.loaded(data)

        #expect(content.language == .plain)
        #expect(content.language.name(in: Self.en) == "Plain text")
        guard case .line(let line) = content.rows.first?.kind else {
            Issue.record("The diff has no line")
            return
        }
        #expect(line.spans == [HighlightedSpan("fn main() {}")])
    }

    @Test("a language or a class this build does not know shows as plain text", arguments: [
        ("rust", DiffLanguage.other("rust")),
        ("", DiffLanguage.plain),
    ])
    func unknownLanguage(name: String, language: DiffLanguage) async throws {
        let data = try DiffFixtures.fileData { file in
            file["language"] = name
            file["lines"] = [["kind": "teleport", "old": 1, "new": 1, "spans": [["class": "lifetime", "text": "'a"]]]]
        }
        let content = try await DiffFixtures.loaded(data)

        #expect(content.language == language)
        guard case .line(let line) = content.rows.first?.kind else {
            Issue.record("The diff has no line")
            return
        }
        #expect(line.kind == .context)
        #expect(line.spans == [HighlightedSpan("'a", kind: .plain)])
    }

    @Test("a capped diff shows its notice")
    func capped() async throws {
        let content = try await DiffFixtures.loaded(try DiffFixtures.fileData { $0["truncated"] = true })

        #expect(content.isTruncated)
        #expect(content.isEmpty == false)
    }

    @Test("a binary file has no lines and says so")
    func binary() async throws {
        let data = try DiffFixtures.fileData { file in
            file["lines"] = []
            file["notes"] = []
            file["additions"] = NSNull()
            file["deletions"] = NSNull()
        }
        let content = try await DiffFixtures.loaded(data)

        #expect(content.isEmpty)
        #expect(content.countsReading(in: Self.en) == nil)
    }

    @Test("a very long line is kept whole, to wrap")
    func longLine() async throws {
        let long = String(repeating: "x", count: 4_000)
        let data = try DiffFixtures.fileData { file in
            file["lines"] = [["kind": "ctx", "old": 1, "new": 1, "spans": [["class": "string", "text": long]]]]
        }
        let content = try await DiffFixtures.loaded(data)

        guard case .line(let line) = content.rows.first?.kind else {
            Issue.record("The diff has no line")
            return
        }
        #expect(line.text == long)
    }

    @Test("Next file wraps to the first flagged file")
    func nextWraps() async throws {
        let model = DiffFixtures.model(index: 1)
        #expect(model.position.map { $0.resolved(in: Self.en) } == "2 of 3")
        #expect(model.canPage)

        // The image has no stored diff, so Next skips it and wraps.
        await model.showNext()
        #expect(model.target.index == 0)
        #expect(try #require(model.target.files.first).isFlagged)
        #expect(model.position.map { $0.resolved(in: Self.en) } == "1 of 3")
        #expect(model.state == .file)

        await model.showNext()
        #expect(model.target.index == 1)
    }

    @Test("Previous file wraps to the last file with a diff")
    func previousWraps() async {
        let model = DiffFixtures.model(index: 0)

        await model.showPrevious()

        #expect(model.target.index == 1)
    }

    @Test("a review with one file to show does not page")
    func onePage() async {
        let files = [DiffFixtures.files[0], DiffFixtures.files[2]]
        let model = DiffModel(target: DiffFixtures.target(index: 0, files: files), api: FixtureAPI().client)

        await model.showNext()

        #expect(model.canPage == false)
        #expect(model.target.index == 0)
    }

    @Test("a 409 reloads the files and asks again for the same path")
    func filesChanged() async throws {
        let calls = OSAllocatedUnfairLock(initialState: [String]())
        let conflict = try DiffFixtures.filesChangedData()
        let first: @Sendable (String) -> Bool = { operation in
            operation == Operations.GetMyReviewFile.id && calls.withLock { $0.count(where: { $0 == operation }) } == 1
        }
        let api = FixtureAPI(
            onSend: { operation, _ in calls.withLock { $0.append(operation) } },
            answering: { first($0) ? conflict : nil },
            status: { first($0) ? 409 : nil }
        )
        // The list moved the sign-in view from index 4 to the fixture's 0.
        let stale = [ReviewFileRow(index: 4, path: "mobile/ios/Stride/SignIn/SignInView.swift", isFlagged: true)]
        let model = DiffModel(target: DiffFixtures.target(index: 4, version: "v0", files: stale), api: api.client)

        await model.load()

        #expect(calls.withLock { $0 } == [Operations.GetMyReviewFile.id, Operations.GetMyReview.id, Operations.GetMyReviewFile.id])
        #expect(model.state == .file)
        #expect(model.target.index == 0)
        #expect(model.target.filesVersion == DiffFixtures.filesVersion)
        #expect(model.target.files.count == 3)
    }

    @Test("after a 409 the new list is cached, so the file is kept for offline use")
    func filesChangedCaches() async throws {
        let container = try TemporaryContainer()
        let cache = Cache(container: container.url, now: { Self.fetched })
        let sent = OSAllocatedUnfairLock(initialState: 0)
        let conflict = try DiffFixtures.filesChangedData()
        let first: @Sendable (String) -> Bool = { operation in
            operation == Operations.GetMyReviewFile.id && sent.withLock { $0 } == 1
        }
        let api = FixtureAPI(
            onSend: { operation, _ in if operation == Operations.GetMyReviewFile.id { sent.withLock { $0 += 1 } } },
            answering: { first($0) ? conflict : nil },
            status: { first($0) ? 409 : nil }
        )
        let model = DiffModel(target: DiffFixtures.target(index: 0, version: "v0"), api: api.client, cache: cache)
        await model.load()
        #expect(model.state == .file)

        let key = CacheKey<Components.Schemas.ReviewFileDiff>.reviewFile(taskID: 4812, index: 0, filesVersion: DiffFixtures.filesVersion)
        let kept = try await cache.cached(key)
        #expect(kept?.value.path == "lib/example/greeting.ex")
        withExtendedLifetime(container) {}
    }

    @Test("a page while the new list is being saved is not undone by the 409's reload")
    func pageDuringReload() async throws {
        // The cache reads its clock while it saves the new list; the first
        // read waits until the test has paged.
        let saving = OSAllocatedUnfairLock(initialState: false)
        let gate = DispatchSemaphore(value: 0)
        let container = try TemporaryContainer()
        let cache = Cache(container: container.url, now: {
            let first = saving.withLock { entered in
                defer { entered = true }
                return entered == false
            }
            if first { gate.wait() }
            return Self.fetched
        })
        let sent = OSAllocatedUnfairLock(initialState: 0)
        let conflict = try DiffFixtures.filesChangedData()
        let first: @Sendable (String) -> Bool = { operation in
            operation == Operations.GetMyReviewFile.id && sent.withLock { $0 } == 1
        }
        let api = FixtureAPI(
            onSend: { operation, _ in if operation == Operations.GetMyReviewFile.id { sent.withLock { $0 += 1 } } },
            answering: { first($0) ? conflict : nil },
            status: { first($0) ? 409 : nil }
        )
        let stale = [
            ReviewFileRow(index: 4, path: "mobile/ios/Stride/SignIn/SignInView.swift", isFlagged: true),
            ReviewFileRow(index: 5, path: "lib/other.ex"),
        ]
        let model = DiffModel(target: DiffFixtures.target(index: 4, version: "v0", files: stale), api: api.client, cache: cache)

        let loading = Task { await model.load() }
        do {
            defer { gate.signal() }
            await waitUntil { saving.withLock { $0 } }
            let paging = Task { await model.showNext() }
            await waitUntil { model.target.index == 5 }
            gate.signal()
            await paging.value
        }
        await loading.value

        #expect(model.target.index == 5)
        #expect(model.target.filesVersion == "v0")
        withExtendedLifetime(container) {}
    }

    @Test("a late answer for a file paged away from never replaces the newer one")
    func lateAnswerDropped() async throws {
        let gate = DispatchSemaphore(value: 0)
        let sent = OSAllocatedUnfairLock(initialState: 0)
        let old = try DiffFixtures.fileData { $0["path"] = "lib/old.ex" }
        let api = FixtureAPI(
            onSend: { operation, _ in if operation == Operations.GetMyReviewFile.id { sent.withLock { $0 += 1 } } },
            answering: { operation in
                guard operation == Operations.GetMyReviewFile.id, sent.withLock({ $0 }) == 1 else { return nil }
                gate.wait()
                return old
            }
        )
        let model = DiffModel(target: DiffFixtures.target(index: 0), api: api.client)

        let loading = Task { await model.load() }
        do {
            defer { gate.signal() }
            await waitUntil { sent.withLock { $0 } == 1 }
            await model.showNext()
            #expect(model.target.index == 1)
        }
        await loading.value

        #expect(model.content?.path == "lib/example/greeting.ex")
        #expect(model.target.index == 1)
    }

    @Test("coming back online loads the file by itself")
    func reconnectLoads() async {
        let connection = ConnectivitySwitch(online: false)
        let isOffline = OSAllocatedUnfairLock(initialState: true)
        let model = DiffModel(
            target: DiffFixtures.target(index: 0),
            api: FixtureAPI(isOffline: { isOffline.withLock { $0 } }).client,
            connectivity: connection.connectivity
        )
        let observing = Task { await model.observe() }
        defer { observing.cancel() }
        await waitUntil { connection.isListening }
        await model.load()
        #expect(model.state == .nothingSaved)

        isOffline.withLock { $0 = false }
        connection.set(online: true)
        await waitUntil { model.state == .file }
        #expect(model.isOnline)
        #expect(model.content?.path == "lib/example/greeting.ex")
    }

    @Test("a 409 for a path the new list lacks, or a second 409, shows the file is gone")
    func filesChangedGone() async throws {
        let conflict = try DiffFixtures.filesChangedData()
        let gonePath = [ReviewFileRow(index: 4, path: "lib/removed.ex")]
        // Only the first ask is a 409, so asking for some other file in the
        // new list would show that file rather than end gone.
        let asks = OSAllocatedUnfairLock(initialState: 0)
        let firstAsk: @Sendable (String) -> Bool = { id in
            id == Operations.GetMyReviewFile.id && asks.withLock { $0 } == 1
        }
        let removed = DiffModel(
            target: DiffFixtures.target(index: 4, version: "v0", files: gonePath),
            api: FixtureAPI(
                onSend: { id, _ in if id == Operations.GetMyReviewFile.id { asks.withLock { $0 += 1 } } },
                answering: { firstAsk($0) ? conflict : nil },
                status: { firstAsk($0) ? 409 : nil }
            ).client
        )
        await removed.load()
        #expect(removed.state == .gone)
        #expect(asks.withLock { $0 } == 1)

        let again = DiffModel(
            target: DiffFixtures.target(index: 0, version: "v0"),
            api: FixtureAPI(answering: { $0 == Operations.GetMyReviewFile.id ? conflict : nil }, status: {
                $0 == Operations.GetMyReviewFile.id ? 409 : nil
            }).client
        )
        await again.load()
        #expect(again.state == .gone)
        #expect(again.content == nil)
    }

    @Test("a 404 shows the file is gone")
    func notFound() async throws {
        let body = try JSONSerialization.data(withJSONObject: ["error": "not_found"])
        let model = DiffFixtures.model(body, statuses: [Operations.GetMyReviewFile.id: 404])

        await model.load()

        #expect(model.state == .gone)
    }

    @Test("offline reads the cached file, and with nothing saved says so")
    func offline() async throws {
        let container = try TemporaryContainer()
        let cache = Cache(container: container.url, now: { Self.fetched })
        // A file is kept under its review, which the review screen saves.
        await ReviewModel(taskID: 4812, api: FixtureAPI().client, cache: cache).load()
        let online = DiffModel(target: DiffFixtures.target(index: 0), api: FixtureAPI().client, cache: cache, now: { Self.fetched })
        await online.load()
        #expect(online.offlineBanner == nil)

        let unreachable = FixtureAPI(unreachable: [Operations.GetMyReviewFile.id]).client
        let offline = DiffModel(target: DiffFixtures.target(index: 0), api: unreachable, cache: cache)
        await offline.load()
        #expect(offline.state == .file)
        #expect(offline.content?.path == "lib/example/greeting.ex")
        #expect(offline.offlineBanner == OfflineBannerContent(fetchedAt: Self.fetched))

        let other = DiffModel(target: DiffFixtures.target(index: 1), api: unreachable, cache: cache)
        await other.load()
        #expect(other.state == .nothingSaved)
        withExtendedLifetime(container) {}
    }

    @Test("a refresh error keeps the file shown")
    func refreshErrorKeeps() async {
        let isOffline = OSAllocatedUnfairLock(initialState: false)
        let model = DiffModel(
            target: DiffFixtures.target(index: 0),
            api: FixtureAPI(isOffline: { isOffline.withLock { $0 } }).client,
            now: { Self.fetched }
        )
        await model.load()

        isOffline.withLock { $0 = true }
        await model.load()

        #expect(model.content?.path == "lib/example/greeting.ex")
        #expect(model.lastLoadFailed)
        #expect(model.offlineBanner == OfflineBannerContent(fetchedAt: Self.fetched))
    }

    @Test("the router opens a file with its own model")
    func routerModel() {
        let router = AppRouter(api: FixtureAPI().client)
        let model = router.diffModel(for: DiffFixtures.target(index: 1))

        #expect(model.target.index == 1)
        #expect(model.state == .loading)
    }

    @Test("the review content opens only a file with a stored diff")
    func reviewTarget() async throws {
        let model = ReviewModel(taskID: 4812, api: FixtureAPI().client)
        await model.load()
        let content = try #require(model.content)

        let first = try #require(content.files.first)
        let third = try #require(content.files.dropFirst(2).first)
        #expect(content.fileTarget(for: first) == DiffFixtures.target(index: 0))
        #expect(content.fileTarget(for: third) == nil)
    }
}
