import Foundation

/// What a store file looks like before SwiftData opens it.
enum StoreFile: Equatable {
    case missing
    case sqlite
    /// The file is there but is not a SQLite database.
    case damaged
    /// The file is there but cannot be read, as while the phone is locked.
    case unreadable

    private static let header = Data("SQLite format 3\u{0}".utf8)

    static func check(_ file: URL) -> StoreFile {
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return .missing }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return .unreadable }
        defer { try? handle.close() }

        guard let start = try? handle.read(upToCount: header.count) else { return .unreadable }

        // SQLite makes an empty file into a database.
        if start.isEmpty || start == header { return .sqlite }
        return .damaged
    }
}
