import Foundation
import Observation
import StrideKit

/// What the file screen shows of one file of a pending review. It asks the
/// API for the file, keeps each answer in the cache and shows the cached file
/// with its fetch time while offline. Next and Previous page through the
/// review's files that have a stored diff, wrapping at either end, and only
/// the file asked for last is ever shown.
@MainActor
@Observable
final class DiffModel {
    /// The file shown, with the review's file list.
    private(set) var target: ReviewFileTarget
    private(set) var content: DiffContent?
    /// When the shown file was fetched, for the offline banner.
    private(set) var fetchedAt: Date?
    private(set) var isOnline = true
    /// The last request failed, so what shows may be out of date.
    private(set) var lastLoadFailed = false
    /// The file is no longer in the review.
    private(set) var isGone = false

    @ObservationIgnored private let api: (any StrideAPI)?
    @ObservationIgnored private let cache: Cache?
    @ObservationIgnored private let connectivity: Connectivity
    @ObservationIgnored private let now: @Sendable () -> Date

    /// Numbers each request, so an answer for a file the person has paged
    /// away from never replaces the one asked for since.
    @ObservationIgnored private var requests = 0

    init(
        target: ReviewFileTarget,
        api: (any StrideAPI)?,
        cache: Cache? = nil,
        connectivity: Connectivity = .system,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.target = target
        self.api = api
        self.cache = cache
        self.connectivity = connectivity
        self.now = now
    }

    // MARK: What the screen shows

    /// Offline, or the server could not be reached.
    var isOffline: Bool { !isOnline || lastLoadFailed }

    var offlineBanner: OfflineBannerContent? {
        guard isOffline, content != nil, let fetchedAt else { return nil }

        return OfflineBannerContent(fetchedAt: fetchedAt)
    }

    var state: DiffScreenState {
        if isGone { return .gone }
        if content != nil { return .file }
        return isOffline ? .nothingSaved : .loading
    }

    /// The files with a stored diff, the only ones the screen can show.
    var openable: [ReviewFileRow] { target.files.filter(\.opens) }

    /// Next and Previous have another file to go to.
    var canPage: Bool { openable.count > 1 }

    /// "1 of 6": the shown file's place in the review's list, which counts
    /// every file, or nil when the list lacks it.
    var position: LocalizedStringResource? {
        guard let place = target.files.firstIndex(where: { $0.index == target.index }) else { return nil }

        return .diffPosition(position: String(place + 1), count: target.files.count)
    }

    // MARK: Loading

    /// Asks the server for the file and keeps it. When the request fails, the
    /// file shown stays, or the cached one shows if nothing does yet. When the
    /// review's files changed since it loaded, it reloads the list once and
    /// asks again for the same path.
    func load() async {
        requests += 1
        let request = requests
        guard let api else { return }

        await ask(for: target, request: request, using: api, mayReload: true)
    }

    /// Follows the connection until the caller stops, asking again when it
    /// comes back.
    func observe() async {
        for await state in connectivity.states() {
            let cameBack = !isOnline && state == .online
            isOnline = state == .online
            if cameBack { await load() }
        }
    }

    /// Shows the next file with a stored diff, after the last the first. The
    /// list puts flagged files first, so it wraps to the first flagged one.
    func showNext() async {
        await page(by: 1)
    }

    func showPrevious() async {
        await page(by: -1)
    }

    // MARK: Helpers

    private func page(by step: Int) async {
        let files = openable
        guard files.count > 1 else { return }

        let place = files.firstIndex(where: { $0.index == target.index }) ?? (step > 0 ? -1 : 0)
        let next = files[(place + step + files.count) % files.count]
        guard let index = next.index else { return }

        target = ReviewFileTarget(taskID: target.taskID, index: index, filesVersion: target.filesVersion, files: target.files)
        content = nil
        fetchedAt = nil
        isGone = false
        lastLoadFailed = false
        await load()
    }

    private func show(_ file: Components.Schemas.ReviewFileDiff, fetchedAt: Date) {
        content = DiffContent(file)
        self.fetchedAt = fetchedAt
        lastLoadFailed = false
        isGone = false
    }

    private func showGone() {
        isGone = true
        content = nil
        lastLoadFailed = false
    }

    /// Asks for one file and shows the answer, unless the person has asked
    /// for another since. A 409 reloads the review's files the first time.
    private func ask(for target: ReviewFileTarget, request: Int, using api: any StrideAPI, mayReload: Bool) async {
        let epoch = await cache?.epoch
        let answer = await Self.fetch(target, using: api)
        guard request == requests else { return }

        switch answer {
        case .file(let file):
            show(file, fetchedAt: now())
            await keep(file, for: target, since: epoch)
        case .filesChanged where mayReload:
            await reloadFiles(request: request, using: api)
        case .gone, .filesChanged:
            showGone()
        case .failed:
            await fail(request: request)
        }
    }

    /// The review's files changed: takes the new list and version, and asks
    /// once more for the shown file's path, which is gone if the list lacks it.
    private func reloadFiles(request: Int, using api: any StrideAPI) async {
        let path = target.files.first(where: { $0.index == target.index })?.path
        let epoch = await cache?.epoch
        let detail = await Self.fetchDetail(target.taskID, using: api)
        guard request == requests else { return }
        guard let detail else { return await fail(request: request) }

        // The cache keeps a file under its review's list, so the new list goes
        // in first; it drops the files kept for the old one.
        if let cache, let epoch {
            _ = try? await cache.store(detail, for: .review(taskID: target.taskID), since: epoch)
        }
        // The person may have paged while the list was being saved.
        guard request == requests else { return }

        let files = ReviewContent.flaggedFirst(detail.files.map(ReviewFileRow.init))
        guard let index = files.first(where: { $0.path == path })?.index else { return showGone() }

        target = ReviewFileTarget(taskID: target.taskID, index: index, filesVersion: detail.filesVersion, files: files)
        await ask(for: target, request: request, using: api, mayReload: false)
    }

    /// A failure says nothing about a file already shown.
    private func fail(request: Int) async {
        lastLoadFailed = true
        let key = CacheKey<Components.Schemas.ReviewFileDiff>.reviewFile(
            taskID: target.taskID, index: target.index, filesVersion: target.filesVersion
        )
        guard content == nil, let cached = try? await cache?.cached(key) else { return }
        guard request == requests, content == nil else { return }

        show(cached.value, fetchedAt: cached.fetchedAt)
        lastLoadFailed = true
    }

    /// Saves the file for offline use, under its review, which the review
    /// screen saved. One that set out before a sign-out is refused, and a
    /// cache that cannot be written only costs the copy.
    private func keep(_ file: Components.Schemas.ReviewFileDiff, for target: ReviewFileTarget, since epoch: Cache.Epoch?) async {
        guard let cache, let epoch else { return }

        let key = CacheKey<Components.Schemas.ReviewFileDiff>.reviewFile(
            taskID: target.taskID, index: target.index, filesVersion: target.filesVersion
        )
        _ = try? await cache.store(file, for: key, since: epoch)
    }

    private enum Answer: Sendable {
        case file(Components.Schemas.ReviewFileDiff)
        /// 404: the file, or the review, is gone.
        case gone
        /// 409: the review's files changed since the list was loaded.
        case filesChanged
        case failed
    }

    private nonisolated static func fetch(_ target: ReviewFileTarget, using api: any StrideAPI) async -> Answer {
        let answer = try? await api.getMyReviewFile(
            path: .init(taskId: target.taskID, index: target.index),
            query: .init(filesVersion: target.filesVersion)
        )
        switch answer {
        case .ok(let response):
            guard let file = try? response.body.json.data else { return .failed }
            return .file(file)
        case .notFound:
            return .gone
        case .conflict:
            return .filesChanged
        default:
            return .failed
        }
    }

    private nonisolated static func fetchDetail(_ taskID: Int, using api: any StrideAPI) async -> Components.Schemas.ReviewDetail? {
        guard case .ok(let response) = try? await api.getMyReview(path: .init(taskId: taskID)) else { return nil }

        return try? response.body.json.data
    }
}
