import Foundation

/// How VoiceOver reads a file's path: its name in its folder, such as
/// "greeting.ex in lib/example", since the audit fails a bare path as not
/// human-readable (W2796).
enum FilePlace {
    /// The name in its folder, or the path itself when it has no folder.
    static func reading(of path: String, in locale: Locale) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }

        let resource = LocalizedStringResource.reviewFileIn(
            name: String(path[path.index(after: slash)...]),
            folder: String(path[..<slash])
        )
        return resource.resolved(in: locale)
    }
}
