import Foundation

/// An empty file that says this install has started with a clean Keychain.
///
/// iOS deletes the app group's container with the app but keeps its Keychain
/// items, so a missing marker means any items come from a previous install. The
/// container is shared, so the extensions see the marker too.
struct InstallMarker: Sendable {
    let url: URL

    init(container: URL) {
        url = container.appending(path: "install-marker", directoryHint: .notDirectory)
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// Writes the file unprotected, because the app can be launched before the
    /// device is first unlocked.
    func create() throws {
        try Data().write(to: url, options: .noFileProtection)
    }
}
