import Foundation
import Testing
@testable import Stride

/// The app's own text, against the files the string catalog is generated from.
struct LocalizationTests {
    /// The shared strings' locale, by the name iOS gives it.
    static let locales = [
        "de": "de", "en": "en", "es": "es", "fr": "fr", "ja": "ja", "pt": "pt", "zh-Hans": "zh"
    ]

    /// The counts each plural is shown with: none, one and many.
    static let counts = [0, 1, 5]

    @Test("the app ships every locale and no other")
    func shippedLocales() {
        #expect(Set(Bundle.main.localizations) == Set(Self.locales.keys))
    }

    @Test("every key exists in all seven locales", arguments: locales.keys.sorted())
    func everyKey(locale: String) throws {
        let shared = try SharedStrings(Self.locales[locale])
        let bundle = try Self.bundle(locale)
        let keys = Array(shared.strings.keys) + Array(shared.plurals.keys)

        #expect(keys.count >= 30)
        for key in keys {
            let text = bundle.localizedString(forKey: key, value: nil, table: nil)
            #expect(text != key && text.isEmpty == false, "\(key) is missing in \(locale)")
        }
    }

    @Test("the app shows the shared text", arguments: locales.keys.sorted())
    func sharedText(locale: String) throws {
        let shared = try SharedStrings(Self.locales[locale])
        let bundle = try Self.bundle(locale)
        let plain = shared.strings.filter { SharedStrings.placeholders(in: $0.value).isEmpty }

        #expect(plain.count >= 10)
        for (key, text) in plain {
            #expect(bundle.localizedString(forKey: key, value: nil, table: nil) == text)
        }
    }

    @Test("the Info.plist names Face ID's reason, in English")
    func faceIDReason() throws {
        let shared = try SharedStrings("en")
        // `infoDictionary`, not `object(forInfoDictionaryKey:)`: the latter
        // answers from InfoPlist.strings even when the Info.plist lacks the key,
        // and iOS refuses Face ID to an app whose Info.plist lacks it.
        let reason = Bundle.main.infoDictionary?["NSFaceIDUsageDescription"] as? String

        #expect(reason == shared.strings["info_plist_face_id_usage"])
    }

    @Test("Face ID's reason is translated in every locale", arguments: locales.keys.sorted())
    func faceIDReasonTranslated(locale: String) throws {
        let shared = try SharedStrings(Self.locales[locale])
        let bundle = try Self.bundle(locale)
        let text = bundle.localizedString(forKey: "NSFaceIDUsageDescription", value: nil, table: "InfoPlist")

        #expect(text == shared.strings["info_plist_face_id_usage"])
    }

    @Test("%{name} placeholders become positional specifiers", arguments: locales.keys.sorted())
    func placeholders(locale: String) throws {
        let source = try SharedStrings("en")
        let shared = try SharedStrings(Self.locales[locale])
        let bundle = try Self.bundle(locale)
        let formatted = source.strings.filter { SharedStrings.placeholders(in: $0.value).isEmpty == false }

        #expect(formatted.isEmpty == false)
        for (key, english) in formatted {
            let names = SharedStrings.placeholders(in: english)
            let format = bundle.localizedString(forKey: key, value: nil, table: nil)
            let text = try #require(shared.strings[key])

            #expect(format.contains("{") == false)
            for position in names.indices {
                #expect(format.contains("%\(position + 1)$"), "\(key) in \(locale) lacks argument \(position + 1)")
            }
            #expect(Self.render(format, names, locale) == Self.expected(text, names))
        }
    }

    @Test("plural forms render for 0, 1 and many", arguments: locales.keys.sorted(), counts)
    func plurals(locale: String, count: Int) throws {
        let source = try SharedStrings("en")
        let shared = try SharedStrings(Self.locales[locale])
        let bundle = try Self.bundle(locale)
        let category = Self.category(of: count, in: locale)

        #expect(source.plurals.isEmpty == false)
        for (key, forms) in source.plurals {
            let names = SharedStrings.placeholders(in: try #require(forms["other"]))
            let localForms = try #require(shared.plurals[key])
            let text = try #require(localForms[category] ?? localForms["other"])
            let format = bundle.localizedString(forKey: key, value: nil, table: nil)

            #expect(
                Self.render(format, names, locale, count: count) == Self.expected(text, names, count: count),
                "\(key) in \(locale) for \(count)"
            )
        }
    }

    @Test("the typed accessors pass each argument to its placeholder")
    func typedAccessors() {
        #expect(Self.text(.targetTaskProgress(done: 2, count: 5), "ja") == "タスク 5 件中 2 件")
        #expect(Self.text(.targetTaskProgress(done: 1, count: 1), "de") == "1 von 1 Aufgabe")
        #expect(Self.text(.targetGoalCount(count: 0), "pt") == "0 meta")
        #expect(Self.text(.targetGoalCount(count: 3), "en") == "3 goals")
        #expect(Self.text(.goalArchivedCount(count: 4), "zh-Hans").contains("4"))
        #expect(
            Self.text(.targetRiskSlip(estimate: "May 4", targetDate: "May 1"), "de")
                == "Beim aktuellen Tempo wäre der Abschluss am May 4 und damit nach dem Zieldatum May 1. "
                + "Reduzieren Sie die verbleibende Arbeit oder verschieben Sie das Zieldatum."
        )
    }

    private static func text(_ resource: LocalizedStringResource, _ locale: String) -> String {
        var resource = resource
        resource.locale = Locale(identifier: locale)
        return String(localized: resource)
    }

    /// The CLDR plural category iOS picks for `count`: fr and pt read 0 as one,
    /// and ja and zh have only `other`.
    private static func category(of count: Int, in locale: String) -> String {
        switch locale {
        case "ja", "zh-Hans": "other"
        case "fr", "pt": count <= 1 ? "one" : "other"
        default: count == 1 ? "one" : "other"
        }
    }

    /// The sample value of a placeholder: the count for `count`, a fixed number
    /// for `done`, and the placeholder's own name in angle quotes for text.
    private static func value(of name: String, count: Int) -> CVarArg {
        switch name {
        case "count": count
        case "done": 2
        default: "‹\(name)›"
        }
    }

    private static func render(_ format: String, _ names: [String], _ locale: String, count: Int = 3) -> String {
        String(format: format, locale: Locale(identifier: locale), arguments: names.map { value(of: $0, count: count) })
    }

    private static func expected(_ text: String, _ names: [String], count: Int = 3) -> String {
        names.reduce(text) { text, name in
            text.replacingOccurrences(of: "{\(name)}", with: String(describing: value(of: name, count: count)))
        }
    }

    private static func bundle(_ locale: String) throws -> Bundle {
        let url = try #require(Bundle.main.url(forResource: locale, withExtension: "lproj"))
        return try #require(Bundle(url: url))
    }
}
