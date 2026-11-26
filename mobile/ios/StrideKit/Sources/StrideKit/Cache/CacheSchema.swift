import Foundation
import SwiftData

/// The cache's first schema.
///
/// A later build that changes `Entry` adds `CacheSchemaV2` and a stage to
/// `CacheMigrationPlan`. A store that no stage can bring forward is reset, since
/// everything in it can be fetched again.
enum CacheSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] { [Entry.self] }

    /// One response, encoded as JSON from its StrideKit type, with the time it
    /// was fetched.
    ///
    /// The payload and its fetch time are one row, so a reader sees either the
    /// whole old response or the whole new one.
    @Model
    final class Entry {
        /// The kind and the API's id, as "review/42".
        @Attribute(.unique) var key: String
        var kind: String
        /// The key of the entry this one belongs to, as a review's for one of its
        /// files. It goes when that entry goes.
        var parentKey: String?
        /// Which list of its parent's this entry was read from, as a review
        /// file's files version. Storing one of another generation drops it.
        var generation: String?
        var fetchedAt: Date
        var payload: Data

        init(key: String, kind: String, parentKey: String?, generation: String?, fetchedAt: Date, payload: Data) {
            self.key = key
            self.kind = kind
            self.parentKey = parentKey
            self.generation = generation
            self.fetchedAt = fetchedAt
            self.payload = payload
        }
    }
}

typealias CacheEntry = CacheSchemaV1.Entry

enum CacheMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [CacheSchemaV1.self] }

    static var stages: [MigrationStage] { [] }
}
