import Foundation
import os
import SwiftData
import Testing

@testable import StrideKit

@Suite(.timeLimit(.minutes(1)))
struct CacheTests {
    private let container: TemporaryDirectory
    private let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_795_000_000))
    private let api: any StrideAPI = FixtureAPI().client

    init() throws {
        container = try TemporaryDirectory()
    }

    // MARK: Storing and reading

    @Test("stores and reads the decisions list with its fetch time")
    func decisions() async throws {
        let cache = makeCache()
        let decisions = try await decisionList()

        let fetchedAt = try await cache.store(decisions, for: .decisions, since: cache.epoch)

        let cached = try #require(try await cache.cached(.decisions))
        #expect(cached.value == decisions)
        #expect(cached.fetchedAt == clock.withLock { $0 })
        #expect(fetchedAt == cached.fetchedAt)
    }

    @Test("an empty cache reads as nothing cached")
    func empty() async throws {
        let cache = makeCache()

        #expect(try await cache.cached(.decisions) == nil)
        #expect(try await cache.cached(.review(taskID: 1)) == nil)
        #expect(try await cache.cached(.reviewFile(taskID: 1, index: 0, filesVersion: "v1")) == nil)
    }

    @Test("a newer response replaces the older one, with its own fetch time")
    func replaces() async throws {
        let cache = makeCache()
        var decisions = try await decisionList()
        try await cache.store(decisions, for: .decisions, since: cache.epoch)

        decisions.summary.waiting = 99
        let later = advanceClock(by: 60)
        try await cache.store(decisions, for: .decisions, since: cache.epoch)

        let cached = try #require(try await cache.cached(.decisions))
        #expect(cached.value.summary.waiting == 99)
        #expect(cached.fetchedAt == later)
    }

    // MARK: The limits

    @Test("keeps only the last 20 opened reviews")
    func reviewLimit() async throws {
        let cache = makeCache()
        let review = try await reviewDetail()

        for taskID in 1...Cache.openedLimit {
            advanceClock(by: 1)
            try await cache.store(review, for: .review(taskID: taskID), since: cache.epoch)
        }
        // Opening the first again makes the second the oldest.
        advanceClock(by: 1)
        try await cache.store(review, for: .review(taskID: 1), since: cache.epoch)
        advanceClock(by: 1)
        try await cache.store(review, for: .review(taskID: 21), since: cache.epoch)

        #expect(try await cache.cached(.review(taskID: 2)) == nil)
        for taskID in [1] + Array(3...21) {
            #expect(try await cache.cached(.review(taskID: taskID)) != nil, "review \(taskID)")
        }
    }

    @Test("the review just opened is kept even when the clock goes back")
    func clockBack() async throws {
        let cache = makeCache()
        let review = try await reviewDetail()
        for taskID in 1...Cache.openedLimit {
            advanceClock(by: 1)
            try await cache.store(review, for: .review(taskID: taskID), since: cache.epoch)
        }

        advanceClock(by: -3_600)
        try await cache.store(review, for: .review(taskID: 21), since: cache.epoch)

        #expect(try await cache.cached(.review(taskID: 21)) != nil)
        #expect(try await cache.cached(.review(taskID: 1)) == nil)
    }

    @Test("evicting a review removes its files")
    func evictionRemovesFiles() async throws {
        let cache = makeCache()
        let review = try await reviewDetail()
        let file = try await reviewFile()
        try await cache.store(review, for: .review(taskID: 1), since: cache.epoch)
        try await cache.store(file, for: .reviewFile(taskID: 1, index: 0, filesVersion: "v1"), since: cache.epoch)
        #expect(try await cache.cached(.reviewFile(taskID: 1, index: 0, filesVersion: "v1")) != nil)

        for taskID in 2...(Cache.openedLimit + 1) {
            advanceClock(by: 1)
            try await cache.store(review, for: .review(taskID: taskID), since: cache.epoch)
        }

        #expect(try await cache.cached(.review(taskID: 1)) == nil)
        #expect(try await cache.cached(.reviewFile(taskID: 1, index: 0, filesVersion: "v1")) == nil)
    }

    @Test("forgetting a review removes it and its files, and leaves the others")
    func forget() async throws {
        let cache = makeCache()
        let review = try await reviewDetail()
        try await cache.store(review, for: .review(taskID: 1), since: cache.epoch)
        try await cache.store(try await reviewFile(), for: .reviewFile(taskID: 1, index: 0, filesVersion: "v1"), since: cache.epoch)
        try await cache.store(review, for: .review(taskID: 2), since: cache.epoch)

        try await cache.forget(.review(taskID: 1))
        try await cache.forget(.review(taskID: 3))

        #expect(try await cache.cached(.review(taskID: 1)) == nil)
        #expect(try await cache.cached(.reviewFile(taskID: 1, index: 0, filesVersion: "v1")) == nil)
        #expect(try await cache.cached(.review(taskID: 2)) != nil)
    }

    @Test("a file is kept only with its review, and only for its files version")
    func fileNeedsReview() async throws {
        let cache = makeCache()
        let file = try await reviewFile()

        await #expect(throws: CacheError.parentNotCached) {
            try await cache.store(file, for: .reviewFile(taskID: 1, index: 0, filesVersion: "v1"), since: cache.epoch)
        }

        try await cache.store(try await reviewDetail(), for: .review(taskID: 1), since: cache.epoch)
        try await cache.store(file, for: .reviewFile(taskID: 1, index: 0, filesVersion: "v1"), since: cache.epoch)
        #expect(try await cache.cached(.reviewFile(taskID: 1, index: 0, filesVersion: "v2")) == nil)
        #expect(try await cache.cached(.reviewFile(taskID: 1, index: 0, filesVersion: "v1"))?.value == file)
    }

    @Test("a file of a newer files version drops the review's older files")
    func newerFilesVersion() async throws {
        let cache = makeCache()
        let file = try await reviewFile()
        try await cache.store(try await reviewDetail(), for: .review(taskID: 1), since: cache.epoch)
        try await cache.store(try await reviewDetail(), for: .review(taskID: 2), since: cache.epoch)
        try await cache.store(file, for: .reviewFile(taskID: 1, index: 0, filesVersion: "v1"), since: cache.epoch)
        try await cache.store(file, for: .reviewFile(taskID: 1, index: 1, filesVersion: "v1"), since: cache.epoch)
        try await cache.store(file, for: .reviewFile(taskID: 2, index: 0, filesVersion: "v1"), since: cache.epoch)

        try await cache.store(file, for: .reviewFile(taskID: 1, index: 0, filesVersion: "v2"), since: cache.epoch)

        #expect(try await cache.cached(.reviewFile(taskID: 1, index: 0, filesVersion: "v1")) == nil)
        #expect(try await cache.cached(.reviewFile(taskID: 1, index: 1, filesVersion: "v1")) == nil)
        #expect(try await cache.cached(.reviewFile(taskID: 1, index: 0, filesVersion: "v2"))?.value == file)
        // Another review's files stay.
        #expect(try await cache.cached(.reviewFile(taskID: 2, index: 0, filesVersion: "v1"))?.value == file)
        #expect(try await cache.cached(.review(taskID: 1)) != nil)
    }

    // MARK: Wiping

    @Test("wipe removes everything")
    func wipe() async throws {
        let cache = makeCache()
        let marker = InstallMarker(container: container.url)
        try marker.create()
        try await cache.store(try await decisionList(), for: .decisions, since: cache.epoch)
        try await cache.store(try await reviewDetail(), for: .review(taskID: 1), since: cache.epoch)
        try await cache.store(try await reviewFile(), for: .reviewFile(taskID: 1, index: 0, filesVersion: "v1"), since: cache.epoch)

        try await cache.wipe()

        #expect(try await cache.cached(.decisions) == nil)
        #expect(try await cache.cached(.review(taskID: 1)) == nil)
        #expect(try await cache.cached(.reviewFile(taskID: 1, index: 0, filesVersion: "v1")) == nil)
        #expect(marker.exists)

        // It keeps working after a wipe.
        try await cache.store(try await decisionList(), for: .decisions, since: cache.epoch)
        #expect(try await cache.cached(.decisions) != nil)
    }

    @Test("wipe leaves no file of the cache and keeps the install marker")
    func wipeRemovesFiles() async throws {
        let cache = makeCache()
        let marker = InstallMarker(container: container.url)
        try marker.create()
        try await cache.store(try await decisionList(), for: .decisions, since: cache.epoch)

        try await cache.wipe()

        let files = try FileManager.default.contentsOfDirectory(atPath: container.url.path(percentEncoded: false))
        #expect(files == [marker.url.lastPathComponent])
    }

    @Test("an answer that set out before a wipe is not kept")
    func supersededWrite() async throws {
        let cache = makeCache()
        let before = await cache.epoch

        try await cache.wipe()

        await #expect(throws: CacheError.superseded) {
            try await cache.store(try await decisionList(), for: .decisions, since: before)
        }
        #expect(try await cache.cached(.decisions) == nil)
        try await cache.store(try await decisionList(), for: .decisions, since: cache.epoch)
        #expect(try await cache.cached(.decisions) != nil)
    }

    // MARK: Two readers

    @Test("the widget's cache reads what the app stored")
    func secondReader() async throws {
        let app = makeCache()
        let widget = makeCache()
        let decisions = try await decisionList()

        try await app.store(decisions, for: .decisions, since: app.epoch)

        #expect(try await widget.cached(.decisions)?.value == decisions)
    }

    @Test("a write during a read is consistent")
    func writeDuringRead() async throws {
        let writerClock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 0))
        let app = Cache(container: container.url, now: { writerClock.withLock { $0 } })
        let widget = makeCache()
        var first = try await decisionList()
        first.summary.waiting = 0
        try await app.store(first, for: .decisions, since: app.epoch)
        let start = first

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var decisions = start
                for count in 1...40 {
                    decisions.summary.waiting = count
                    writerClock.withLock { $0 = Date(timeIntervalSince1970: TimeInterval(count)) }
                    try await app.store(decisions, for: .decisions, since: app.epoch)
                }
            }
            group.addTask {
                for _ in 0..<40 {
                    // Each read has the count and the fetch time of one write.
                    let cached = try #require(try await widget.cached(.decisions))
                    #expect(TimeInterval(cached.value.summary.waiting) == cached.fetchedAt.timeIntervalSince1970)
                    await Task.yield()
                }
            }
            try await group.waitForAll()
        }

        #expect(try await widget.cached(.decisions)?.value.summary.waiting == 40)
    }

    // MARK: Versions and damage

    @Test("a corrupt store is reset")
    func corruptStore() async throws {
        let file = try storeFile(.afterFirstUnlock)
        try Data("not a database, nor ever was".utf8).write(to: file)
        let cache = makeCache()

        #expect(try await cache.cached(.decisions) == nil)
        try await cache.store(try await decisionList(), for: .decisions, since: cache.epoch)
        #expect(try await cache.cached(.decisions) != nil)
    }

    @Test("a store from another version of the schema is reset")
    func otherSchemaVersion() async throws {
        let file = try storeFile(.afterFirstUnlock)
        do {
            let schema = Schema(versionedSchema: OtherCacheSchema.self)
            let other = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, url: file, cloudKitDatabase: .none)
            )
            let context = ModelContext(other)
            context.insert(OtherCacheSchema.Entry(name: "left by another version", size: 3))
            try context.save()
        }
        let cache = makeCache()

        #expect(try await cache.cached(.decisions) == nil)
        try await cache.store(try await decisionList(), for: .decisions, since: cache.epoch)
        #expect(try await makeCache().cached(.decisions) != nil)
    }

    @Test("a response this version cannot read is nothing cached, and goes")
    func unreadablePayload() async throws {
        let cache = makeCache()
        let elsewhere = CacheKey<[String]>(kind: .decisions, itemID: "me")
        try await cache.store(["not", "a", "decision", "list"], for: elsewhere, since: cache.epoch)

        #expect(try await cache.cached(.decisions) == nil)
        #expect(try await cache.cached(elsewhere) == nil)
    }

    @Test("a store it cannot read is kept, not reset")
    func unreadableStore() async throws {
        let decisions = try await decisionList()
        try await makeCache().store(decisions, for: .decisions, since: Cache.Epoch.first)
        let file = try storeFile(.afterFirstUnlock)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path(percentEncoded: false))
        let locked = makeCache()

        await #expect(throws: CacheError.unavailable) { try await locked.cached(.decisions) }

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path(percentEncoded: false))
        #expect(try await locked.cached(.decisions)?.value == decisions)
    }

    // MARK: Where it lives

    @Test("keeps the decisions readable after the first unlock, the rest only while unlocked, out of backups")
    func protection() async throws {
        let recorded = OSAllocatedUnfairLock<[String: FileProtectionType]>(initialState: [:])
        let cache = Cache(container: container.url, now: { .now }) { protection, directory in
            recorded.withLock { $0[directory.lastPathComponent] = protection }
            try Cache.makeDirectory(protection: protection, at: directory)
        }

        try await cache.store(try await decisionList(), for: .decisions, since: cache.epoch)
        try await cache.store(try await reviewDetail(), for: .review(taskID: 1), since: cache.epoch)

        #expect(recorded.withLock { $0 } == [
            "AfterFirstUnlock": .completeUntilFirstUserAuthentication,
            "WhileUnlocked": .complete
        ])
        let folder = container.url.appending(path: "Cache", directoryHint: .isDirectory)
        #expect(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test("lives in the app group container")
    func appGroup() async throws {
        let named = AppGroup(infoDictionary: [
            AppGroup.identifierKey: "group.example",
            AppGroup.keychainAccessGroupKey: "TEAM.example.shared"
        ])
        let group = try #require(named)
        let unentitled = Cache(group: group, resolve: { _ in nil })
        #expect(unentitled == nil)

        let url = container.url
        let entitled = Cache(group: group, resolve: { $0 == "group.example" ? url : nil })
        let cache = try #require(entitled)
        try await cache.store(try await decisionList(), for: .decisions, since: cache.epoch)

        let store = url.appending(path: "Cache/AfterFirstUnlock/Cache.store", directoryHint: .notDirectory)
        #expect(FileManager.default.fileExists(atPath: store.path(percentEncoded: false)))
    }

    // MARK: Helpers

    private func makeCache() -> Cache {
        let clock = clock
        return Cache(container: container.url, now: { clock.withLock { $0 } })
    }

    @discardableResult
    private func advanceClock(by seconds: TimeInterval) -> Date {
        clock.withLock { now in
            now = now.addingTimeInterval(seconds)
            return now
        }
    }

    private func storeFile(_ store: CacheStore) throws -> URL {
        let directory = container.url.appending(path: "Cache/\(store.rawValue)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "Cache.store", directoryHint: .notDirectory)
    }

    private func decisionList() async throws -> Components.Schemas.DecisionList {
        try await api.listMyDecisions().ok.body.json.data
    }

    private func reviewDetail() async throws -> Components.Schemas.ReviewDetail {
        try await api.getMyReview(path: .init(taskId: 1)).ok.body.json.data
    }

    private func reviewFile() async throws -> Components.Schemas.ReviewFileDiff {
        try await api.getMyReviewFile(path: .init(taskId: 1, index: 0)).ok.body.json.data
    }
}

extension Cache.Epoch {
    /// The epoch of a cache that has never been wiped.
    static var first: Self { Self(wipes: 0) }
}

/// A schema no version of the app has, standing for one from a newer or older build.
enum OtherCacheSchema: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(9, 0, 0) }

    static var models: [any PersistentModel.Type] { [Entry.self] }

    @Model
    final class Entry {
        var name: String
        var size: Int

        init(name: String, size: Int) {
            self.name = name
            self.size = size
        }
    }
}
