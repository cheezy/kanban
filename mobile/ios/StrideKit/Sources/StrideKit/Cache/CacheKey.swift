import Foundation

/// Names one cached response and the type it decodes to.
public struct CacheKey<Value: Codable & Sendable>: Hashable, Sendable {
    let kind: CacheKind
    let itemID: String
    /// The key of the entry this one belongs to.
    let parentKey: String?
    /// The list of its parent's this response was read from; storing it drops
    /// the parent's entries of any other generation.
    let generation: String?

    init(kind: CacheKind, itemID: String, parentKey: String? = nil, generation: String? = nil) {
        self.kind = kind
        self.itemID = itemID
        self.parentKey = parentKey
        self.generation = generation
    }

    var key: String { Self.key(kind, itemID) }

    static func key(_ kind: CacheKind, _ itemID: String) -> String {
        "\(kind.rawValue)/\(itemID)"
    }
}

extension CacheKey where Value == Components.Schemas.DecisionList {
    /// The person's decisions list, from `GET /api/me/decisions`.
    public static var decisions: Self { Self(kind: .decisions, itemID: "me") }
}

extension CacheKey where Value == [Components.Schemas.DecisionItem] {
    /// The person's pending reviews in the server's order, from
    /// `GET /api/me/reviews`.
    public static var reviewQueue: Self { Self(kind: .reviewQueue, itemID: "me") }
}

extension CacheKey where Value == Components.Schemas.ReviewDetail {
    /// One review, from `GET /api/me/reviews/{task_id}`.
    public static func review(taskID: Int) -> Self {
        Self(kind: .review, itemID: String(taskID))
    }
}

extension CacheKey where Value == Components.Schemas.ReviewFileDiff {
    /// One of a review's files, from `GET /api/me/reviews/{task_id}/files/{index}`.
    ///
    /// The files version is part of the key, so a file read from an older list
    /// is never shown beside a newer review, and storing a file of one version
    /// drops the review's files of the others.
    public static func reviewFile(taskID: Int, index: Int, filesVersion: String) -> Self {
        Self(
            kind: .reviewFile,
            itemID: "\(taskID)/\(index)/\(filesVersion)",
            parentKey: CacheKey<Components.Schemas.ReviewDetail>.key(.review, String(taskID)),
            generation: filesVersion
        )
    }
}
