import CoreText
import Testing
import UIKit

struct FontTests {
    private static let weightAxis = 0x7767_6874 // 'wght'

    @Test("the app registers its own variable copy of each family", arguments: ["Geist", "Geist Mono"])
    func registered(family: String) throws {
        #expect(UIFont.familyNames.contains(family))

        let font = CTFontCreateWithFontDescriptor(
            CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary),
            13,
            nil
        )
        let url = try #require(CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)
        let axes = try #require(CTFontCopyVariationAxes(font) as? [[CFString: Any]])

        #expect(url.resolvingSymlinksInPath().path().hasPrefix(Bundle.main.bundleURL.resolvingSymlinksInPath().path()))
        #expect(axes.compactMap { $0[kCTFontVariationAxisIdentifierKey] as? Int } == [Self.weightAxis])
    }

    @Test("every font file an Info.plist lists is in its bundle")
    func listedFilesExist() throws {
        let widgets = try #require(try BuiltBundle.embeddedExtensions()["StrideWidgets"])

        for bundle in [BuiltBundle.app.bundle, widgets.bundle] {
            let files = try #require(bundle.object(forInfoDictionaryKey: "UIAppFonts") as? [String])

            #expect(files == ["Geist-Variable.ttf", "GeistMono-Variable.ttf"])
            for file in files {
                #expect(bundle.url(forResource: file, withExtension: nil) != nil, "\(file) is missing")
            }
            #expect(bundle.url(forResource: "Geist-OFL", withExtension: "txt") != nil, "the licence is missing")
        }
    }
}
