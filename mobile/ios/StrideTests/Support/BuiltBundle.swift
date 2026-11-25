import Foundation
import Testing

/// A built app or extension, read from disk.
struct BuiltBundle {
    let bundle: Bundle

    /// The app that hosts the tests.
    static let app = BuiltBundle(bundle: .main)

    /// The extensions embedded in the app, by name.
    static func embeddedExtensions() throws -> [String: BuiltBundle] {
        let directory = try #require(Bundle.main.builtInPlugInsURL)
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)

        // The test bundle itself is in the same directory, as an .xctest.
        return try urls.filter { $0.pathExtension == "appex" }.reduce(into: [:]) { found, url in
            found[url.deletingPathExtension().lastPathComponent] = BuiltBundle(bundle: try #require(Bundle(url: url)))
        }
    }

    func infoString(_ key: String) -> String? {
        bundle.object(forInfoDictionaryKey: key) as? String
    }

    /// The entitlements the target was built with, without the ones Xcode adds
    /// to every target.
    ///
    /// A simulator build's code signature holds none; the linker puts them in the
    /// executable as a property list.
    func entitlements() throws -> [String: Any] {
        let executable = try Data(contentsOf: #require(bundle.executableURL))
        let key = try #require(
            executable.firstRange(of: Data("application-groups".utf8)),
            "the executable holds no app group entitlement"
        )
        let start = try #require(executable[..<key.lowerBound].lastRange(of: Data("<?xml".utf8)))
        let end = try #require(executable[key.upperBound...].firstRange(of: Data("</plist>".utf8)))
        let list = try PropertyListSerialization.propertyList(
            from: executable[start.lowerBound..<end.upperBound],
            format: nil
        )
        let added = ["application-identifier", "com.apple.developer.team-identifier", "get-task-allow"]

        return try #require(list as? [String: Any]).filter { added.contains($0.key) == false }
    }
}
