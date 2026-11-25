import Foundation

/// A directory that stands for an app group container, removed with the object.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
