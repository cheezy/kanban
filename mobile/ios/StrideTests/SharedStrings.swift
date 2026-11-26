import Foundation
import Testing

/// One locale's file in `mobile/shared/strings/`, which the tests bundle as the
/// `strings` folder.
struct SharedStrings {
    /// Each singular string, by key.
    let strings: [String: String]

    /// Each plural's text, by key and CLDR category.
    let plurals: [String: [String: String]]

    init(_ locale: String?) throws {
        let url = try #require(
            Bundle(for: Anchor.self).url(forResource: locale, withExtension: "json", subdirectory: "strings")
        )
        let file = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]

        strings = try #require(file?["strings"] as? [String: String])
        plurals = try #require(file?["plurals"] as? [String: [String: String]])
    }

    /// The names of the `{name}` placeholders in `text`, in the order they first appear.
    static func placeholders(in text: String) -> [String] {
        var names: [String] = []
        for match in text.matches(of: /\{(\w+)\}/) where names.contains(String(match.1)) == false {
            names.append(String(match.1))
        }
        return names
    }

    /// Finds the bundle of the tests.
    private final class Anchor {}
}
