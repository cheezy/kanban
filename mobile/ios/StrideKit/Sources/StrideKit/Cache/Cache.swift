import Foundation
import SwiftData

/// Keeps the API's responses in the app group container, each with the time it
/// was fetched, so the app can show what it last had while offline and the
/// widget can read the decisions count.
///
/// Every response is kept as JSON encoded from its StrideKit type, keyed by the
/// API's ids, so a build whose type no longer decodes it drops it. The
/// kinds and how many of each are kept are in `CacheKind`. Only the app stores
/// and wipes, through its one `Cache`; an extension only reads, and opens a
/// fresh `Cache` for each read, because a wipe deletes the store files and a
/// long-lived one would keep reading the deleted ones.
///
/// Each method opens its own `ModelContext` and finishes with it before
/// returning, so no context or model leaves the actor and no call waits while
/// it holds one.
public actor Cache {
    /// How many opened reviews, read-only tasks, targets and goals are kept,
    /// from the design's section 11.
    public static let openedLimit = 20

    /// Changes with each wipe. Read it before asking the API and pass it to
    /// `store(_:for:since:)`, so an answer that set out before a sign-out is not
    /// kept after it.
    public struct Epoch: Equatable, Sendable {
        let wipes: Int
    }

    typealias Protect = @Sendable (FileProtectionType, URL) throws -> Void

    private let folder: URL
    private let now: @Sendable () -> Date
    private let protect: Protect
    private var containers: [CacheStore: ModelContainer] = [:]
    private var wipes = 0

    public var epoch: Epoch { Epoch(wipes: wipes) }

    /// Returns nil when the running target is not entitled to the app group.
    public init?(
        group: AppGroup,
        resolve: @Sendable (String) -> URL? = AppGroup.systemContainerURL,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        guard let container = group.containerURL(resolve: resolve) else { return nil }

        self.init(container: container, now: now)
    }

    init(
        container: URL,
        now: @escaping @Sendable () -> Date = { .now },
        protect: @escaping Protect = Cache.makeDirectory
    ) {
        folder = container.appending(path: "Cache", directoryHint: .isDirectory)
        self.now = now
        self.protect = protect
    }

    // MARK: Reading

    /// The cached response with its fetch time, or nil when none is cached or
    /// the one cached is one this build cannot read.
    public func cached<Value>(_ key: CacheKey<Value>) throws(CacheError) -> Cached<Value>? {
        let context = try context(for: key.kind.store)
        guard let entry = try entry(key.key, in: context) else { return nil }

        guard let value = try? JSONDecoder().decode(Value.self, from: entry.payload) else {
            // Written by another version of the app; it is fetched again.
            try remove([entry], from: context)
            return nil
        }

        return Cached(value: value, fetchedAt: entry.fetchedAt)
    }

    // MARK: Storing

    /// Keeps the response with the time now, replacing any older one, and drops
    /// the least recently fetched entries past the kind's limit.
    @discardableResult
    public func store<Value>(
        _ value: Value,
        for key: CacheKey<Value>,
        since epoch: Epoch
    ) throws(CacheError) -> Date {
        guard epoch == self.epoch else { throw .superseded }
        guard let payload = try? JSONEncoder().encode(value) else { throw .invalidValue }

        let context = try context(for: key.kind.store)
        if let parentKey = key.parentKey, try entry(parentKey, in: context) == nil {
            throw .parentNotCached
        }
        if let parentKey = key.parentKey, let generation = key.generation {
            try dropOtherGenerations(under: parentKey, keeping: generation, in: context)
        }

        let fetchedAt = now()
        if let entry = try entry(key.key, in: context) {
            entry.payload = payload
            entry.fetchedAt = fetchedAt
        } else {
            context.insert(
                CacheEntry(
                    key: key.key,
                    kind: key.kind.rawValue,
                    parentKey: key.parentKey,
                    generation: key.generation,
                    fetchedAt: fetchedAt,
                    payload: payload
                )
            )
        }
        if let limit = key.kind.limit {
            try evict(key.kind, keeping: limit, after: key.key, in: context)
        }
        try save(context)

        return fetchedAt
    }

    // MARK: Forgetting

    /// Removes one cached response and the entries that belong to it, such as
    /// a review's files, so a review decided here never reopens offline as
    /// still waiting. Nothing cached under the key is not an error.
    public func forget<Value>(_ key: CacheKey<Value>) throws(CacheError) {
        let context = try context(for: key.kind.store)
        guard let entry = try entry(key.key, in: context) else { return }

        try remove([entry], from: context)
    }

    // MARK: Wiping

    /// Removes everything cached, for a sign-out, a revoked device or another
    /// person. The install marker beside the cache stays.
    public func wipe() throws(CacheError) {
        wipes += 1

        // Empty each store first, so a widget that has it open sees nothing.
        for store in CacheStore.allCases {
            let path = file(of: store).path(percentEncoded: false)
            guard FileManager.default.fileExists(atPath: path), let context = try? context(for: store) else { continue }

            try? context.delete(model: CacheEntry.self)
            try? context.save()
        }
        containers = [:]

        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else { return }

        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            throw .unavailable
        }
    }

    // MARK: Entries

    private func entry(_ key: String, in context: ModelContext) throws(CacheError) -> CacheEntry? {
        var descriptor = FetchDescriptor<CacheEntry>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1

        return try fetch(descriptor, in: context).first
    }

    /// Drops the kind's entries after the newest `limit`, never the one just
    /// stored, so a clock set back cannot evict what was just opened.
    private func evict(
        _ kind: CacheKind,
        keeping limit: Int,
        after stored: String,
        in context: ModelContext
    ) throws(CacheError) {
        let kindName = kind.rawValue
        var descriptor = FetchDescriptor<CacheEntry>(
            predicate: #Predicate { $0.kind == kindName && $0.parentKey == nil && $0.key != stored },
            sortBy: [SortDescriptor(\.fetchedAt, order: .reverse)]
        )
        descriptor.fetchOffset = limit - 1

        try remove(try fetch(descriptor, in: context), from: context)
    }

    /// Drops the parent's entries read from another of its lists, as a review's
    /// files of an older files version.
    private func dropOtherGenerations(
        under parentKey: String,
        keeping generation: String,
        in context: ModelContext
    ) throws(CacheError) {
        let parent: String? = parentKey
        let siblings = FetchDescriptor<CacheEntry>(predicate: #Predicate { $0.parentKey == parent })
        for sibling in try fetch(siblings, in: context) where sibling.generation != generation {
            context.delete(sibling)
        }
    }

    /// Deletes the entries and the entries that belong to them, and saves.
    private func remove(_ entries: [CacheEntry], from context: ModelContext) throws(CacheError) {
        for entry in entries {
            let parentKey: String? = entry.key
            let children = FetchDescriptor<CacheEntry>(predicate: #Predicate { $0.parentKey == parentKey })
            for child in try fetch(children, in: context) {
                context.delete(child)
            }
            context.delete(entry)
        }
        try save(context)
    }

    private func fetch(
        _ descriptor: FetchDescriptor<CacheEntry>,
        in context: ModelContext
    ) throws(CacheError) -> [CacheEntry] {
        do {
            return try context.fetch(descriptor)
        } catch {
            throw .unavailable
        }
    }

    private func save(_ context: ModelContext) throws(CacheError) {
        guard context.hasChanges else { return }

        do {
            try context.save()
        } catch {
            throw .unavailable
        }
    }

    // MARK: Stores

    private func context(for store: CacheStore) throws(CacheError) -> ModelContext {
        if let container = containers[store] { return ModelContext(container) }

        let container = try open(store)
        containers[store] = container
        return ModelContext(container)
    }

    private func directory(of store: CacheStore) -> URL {
        folder.appending(path: store.rawValue, directoryHint: .isDirectory)
    }

    private func file(of store: CacheStore) -> URL {
        directory(of: store).appending(path: "Cache.store", directoryHint: .notDirectory)
    }

    /// Opens the store, resetting one that is damaged or from a version this
    /// build cannot migrate. A store that cannot be read, as while the phone is
    /// locked, is kept: resetting it then would empty the cache at every lock.
    private func open(_ store: CacheStore) throws(CacheError) -> ModelContainer {
        try prepare(store)

        switch StoreFile.check(file(of: store)) {
        case .unreadable: throw .unavailable
        case .damaged: try reset(store)
        case .missing, .sqlite: break
        }

        if let container = try? Self.makeContainer(at: file(of: store)) { return container }

        try reset(store)
        do {
            return try Self.makeContainer(at: file(of: store))
        } catch {
            throw .unavailable
        }
    }

    private func prepare(_ store: CacheStore) throws(CacheError) {
        do {
            try protect(store.protection, directory(of: store))
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var folder = folder
            try folder.setResourceValues(values)
        } catch {
            throw .unavailable
        }
    }

    private func reset(_ store: CacheStore) throws(CacheError) {
        do {
            try FileManager.default.removeItem(at: directory(of: store))
        } catch {
            throw .unavailable
        }
        try prepare(store)
    }

    private static func makeContainer(at file: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: CacheSchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, url: file, cloudKitDatabase: .none)

        return try ModelContainer(
            for: schema,
            migrationPlan: CacheMigrationPlan.self,
            configurations: configuration
        )
    }

    /// Creates the store's directory with its protection class, which the store
    /// and its journal files take when SwiftData creates them.
    static func makeDirectory(protection: FileProtectionType, at directory: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.path(percentEncoded: false)) {
            try manager.setAttributes([.protectionKey: protection], ofItemAtPath: directory.path(percentEncoded: false))
        } else {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: protection]
            )
        }
    }
}
