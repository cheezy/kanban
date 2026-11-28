import Foundation
import Testing

@testable import Stride
@testable import StrideKit

/// The shared `getMyReviewFile` fixture, edited for one test, and the file
/// lists the file screen pages through.
@MainActor
enum DiffFixtures {
    /// The version the `getMyReview` and `getMyReviewFile` fixtures share.
    static let filesVersion = "v1-2026-11-18T09:30:00Z"

    /// The `getMyReviewFile` fixture's body with `edit` applied to its file,
    /// the `data` object.
    static func fileData(editing edit: (inout [String: Any]) throws -> Void = { _ in }) throws -> Data {
        let fixture = try FixtureAPI.fixture(named: Operations.GetMyReviewFile.id)
        var root = try #require(try JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        var file = try #require(root["data"] as? [String: Any])
        try edit(&file)
        root["data"] = file
        return try JSONSerialization.data(withJSONObject: root)
    }

    /// A 409 `files_changed` body, naming the version the list has now.
    static func filesChangedData(version: String = filesVersion) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "error": "files_changed",
            "message": "The task's changed files have changed.",
            "files_version": version,
        ])
    }

    /// The review's files as the `getMyReview` fixture lists them, flagged
    /// first: a flagged file, a file with a diff, and an image without one.
    static let files = [
        ReviewFileRow(index: 0, path: "mobile/ios/Stride/SignIn/SignInView.swift", additions: 120, deletions: 4, isFlagged: true),
        ReviewFileRow(index: 1, path: "mobile/ios/StrideTests/SignInViewModelTests.swift", additions: 64, deletions: 0),
        ReviewFileRow(index: nil, path: "mobile/ios/Stride/Assets.xcassets/Logo.png"),
    ]

    static func target(index: Int, version: String = filesVersion, files: [ReviewFileRow] = files) -> ReviewFileTarget {
        ReviewFileTarget(taskID: 4812, index: index, filesVersion: version, files: files)
    }

    /// A model of the file at `index`, answered from the fixtures with `data`
    /// in place of the file when given.
    static func model(index: Int = 0, _ data: Data? = nil, statuses: [String: Int] = [:]) -> DiffModel {
        let replacements = data.map { [Operations.GetMyReviewFile.id: $0] } ?? [:]
        return DiffModel(target: target(index: index), api: FixtureAPI(replacing: replacements, statuses: statuses).client)
    }

    /// The content of the file `data` describes, or of the fixture's file.
    static func loaded(_ data: Data? = nil, sourceLocation: SourceLocation = #_sourceLocation) async throws -> DiffContent {
        let model = model(data)
        await model.load()
        try #require(model.state == .file, sourceLocation: sourceLocation)
        return try #require(model.content, sourceLocation: sourceLocation)
    }
}
