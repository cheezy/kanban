import Testing

@testable import StrideKit

struct DeviceDetailsTests {
    @Test("keeps a name as the person gave it")
    func name() {
        #expect(DeviceDetails(name: "Pat's iPhone 15 ✨", deviceClass: .phone).name == "Pat's iPhone 15 ✨")
    }

    @Test("drops control and direction characters, and the spaces around the name")
    func strippedName() {
        let name = " \u{202E}Pat\u{0007}'s\u{200B}\u{2067} iPad\u{200F}\n\u{2028} "

        #expect(DeviceDetails(name: name, deviceClass: .tablet).name == "Pat's iPad")
    }

    @Test(
        "a name with nothing to show becomes the product's name",
        arguments: [(DeviceDetails.DeviceClass.phone, "iPhone"), (.tablet, "iPad")]
    )
    func fallbackName(deviceClass: DeviceDetails.DeviceClass, expected: String) {
        #expect(DeviceDetails(name: " \u{202E}\n ", deviceClass: deviceClass).name == expected)
        #expect(DeviceDetails(name: "", deviceClass: deviceClass).name == expected)
        // Joiners and the letters that render as nothing do not show either.
        #expect(DeviceDetails(name: "\u{200D}\u{3164} \u{200C}", deviceClass: deviceClass).name == expected)
        // Nor does what is left after the cut.
        let joinersFirst = String(repeating: "\u{200D}", count: 255) + "Pat"
        #expect(DeviceDetails(name: joinersFirst, deviceClass: deviceClass).name == expected)
    }

    @Test(
        "keeps the joiners and tags that emoji and some scripts are written with",
        arguments: ["Pat's 👨‍👩‍👧 iPhone", "🏴\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F} iPad", "می\u{200C}خواهم"]
    )
    func joinedName(name: String) {
        #expect(DeviceDetails(name: name, deviceClass: .phone).name.unicodeScalars.elementsEqual(name.unicodeScalars))
    }

    @Test("cuts every field to the 255 code points the server takes")
    func limits() {
        let long = String(repeating: "é", count: 300)
        let device = DeviceDetails(
            name: long,
            deviceClass: .phone,
            model: long,
            osVersion: long,
            appVersion: long,
            locale: long,
            timeZone: long
        )
        let fields = [device.name, device.model, device.osVersion, device.appVersion, device.locale, device.timeZone]

        #expect(fields.allSatisfy { $0?.count == 255 })
    }

    @Test(
        "counts the cut in code points, as the server does, and keeps whole characters",
        arguments: [
            // A decomposed é is two code points in one character.
            ("e\u{0301}", 127),
            // A family emoji is five code points in one character.
            ("👨‍👩‍👧", 51),
            // A flag is two.
            ("🇨🇦", 127),
        ]
    )
    func codePointLimits(character: String, keptCharacters: Int) {
        let long = String(repeating: character, count: 300)
        let device = DeviceDetails(name: long, deviceClass: .phone, model: long, timeZone: long)

        for field in [device.name, device.model, device.timeZone] {
            #expect(field?.unicodeScalars.count ?? 0 <= 255)
            #expect(field == String(repeating: character, count: keptCharacters))
        }
    }

    @Test("leaves out a character that would cross the limit rather than split it")
    func characterAtTheLimit() {
        let name = String(repeating: "a", count: 253) + "👨‍👩‍👧"

        #expect(DeviceDetails(name: name, deviceClass: .phone).name == String(repeating: "a", count: 253))
    }

    @Test("leaves out what the system did not give")
    func missingFields() {
        let device = DeviceDetails(name: "iPhone", deviceClass: .phone)

        #expect(device.model == nil)
        #expect(device.osVersion == nil)
        #expect(device.appVersion == nil)
        #expect(device.locale == nil)
        #expect(device.timeZone == nil)
    }
}
