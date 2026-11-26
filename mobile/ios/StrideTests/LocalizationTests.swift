import Foundation
import Testing

/// The app's own text, against the files the string catalog is generated from.
struct LocalizationTests {
    /// The shared strings' locale, by the name iOS gives it.
    static let locales = [
        "de": "de", "en": "en", "es": "es", "fr": "fr", "ja": "ja", "pt": "pt", "zh-Hans": "zh"
    ]

    @Test("the app ships every locale and no other")
    func shippedLocales() {
        #expect(Set(Bundle.main.localizations) == Set(Self.locales.keys))
    }

    @Test("the app shows the shared text", arguments: locales.keys.sorted())
    func sharedText(locale: String) throws {
        let shared = try sharedStrings(#require(Self.locales[locale]))
        let url = try #require(Bundle.main.url(forResource: locale, withExtension: "lproj"))
        let bundle = try #require(Bundle(url: url))
        let plain = shared.filter { $0.value.contains("{") == false }

        #expect(plain.count >= 10)
        for (key, text) in plain {
            #expect(bundle.localizedString(forKey: key, value: nil, table: nil) == text)
        }
    }

    private func sharedStrings(_ locale: String) throws -> [String: String] {
        let url = try #require(
            Bundle(for: Anchor.self).url(forResource: locale, withExtension: "json", subdirectory: "strings")
        )
        let file = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]

        return try #require(file?["strings"] as? [String: String])
    }

    /// Finds the bundle of the tests.
    private final class Anchor {}
}
