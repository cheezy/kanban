import Foundation

/// What the server records about this device when it signs in. The app fills it
/// in from the system, and the token exchange sends it.
public struct DeviceDetails: Equatable, Sendable {
    public enum DeviceClass: String, Sendable {
        case phone
        case tablet
    }

    /// Shown on the web's confirmation page and in the list of devices.
    public let name: String
    public let deviceClass: DeviceClass
    public let model: String?
    public let osVersion: String?
    public let appVersion: String?

    /// A BCP 47 tag, such as `fr-CA`.
    public let locale: String?

    /// A time zone database name, such as `Europe/Paris`.
    public let timeZone: String?

    /// The server refuses a name with control or direction characters, so the
    /// name loses those and the other invisible format characters, keeping the
    /// joiners and tags that emoji and some scripts are written with. It refuses
    /// a field longer than 255 code points (Unicode scalars), so each is cut
    /// short, and a name with nothing that shows, which becomes the product's
    /// name.
    public init(
        name: String,
        deviceClass: DeviceClass,
        model: String? = nil,
        osVersion: String? = nil,
        appVersion: String? = nil,
        locale: String? = nil,
        timeZone: String? = nil
    ) {
        let kept = String(String.UnicodeScalarView(name.unicodeScalars.filter(Self.isKept)))
        let shown = Self.limited(kept.trimmingCharacters(in: .whitespaces))
        self.name = shown.unicodeScalars.contains(where: Self.isVisible) ? shown : Self.fallbackName(for: deviceClass)
        self.deviceClass = deviceClass
        self.model = model.map(Self.limited)
        self.osVersion = osVersion.map(Self.limited)
        self.appVersion = appVersion.map(Self.limited)
        self.locale = locale.map(Self.limited)
        self.timeZone = timeZone.map(Self.limited)
    }

    /// The server takes at most 255 code points (Unicode scalars) in each field.
    /// The cut keeps whole characters, so an accent or an emoji is never split
    /// from the rest of its character.
    private static func limited(_ value: String) -> String {
        var kept = ""
        var scalars = 0

        for character in value {
            scalars += character.unicodeScalars.count
            guard scalars <= limit else { break }
            kept.append(character)
        }

        return kept
    }

    private static let limit = 255

    private static func isKept(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator: false
        case .format: joiners.contains(scalar.value) || tags.contains(scalar.value)
        default: true
        }
    }

    /// As the server decides it: whitespace, format characters and the letters
    /// that render as nothing do not show.
    private static func isVisible(_ scalar: Unicode.Scalar) -> Bool {
        !scalar.properties.isWhitespace
            && scalar.properties.generalCategory != .format
            && !blankLetters.contains(scalar.value)
    }

    /// The zero-width non-joiner and joiner, which join emoji and shape Arabic
    /// and Indic scripts.
    private static let joiners: Set<UInt32> = [0x200C, 0x200D]

    /// The tag characters of subdivision flags, such as Scotland's.
    private static let tags: ClosedRange<UInt32> = 0xE0020...0xE007F

    private static let blankLetters: Set<UInt32> = [0x034F, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x3164, 0xFFA0]

    /// Product names, which are the same in every language.
    private static func fallbackName(for deviceClass: DeviceClass) -> String {
        switch deviceClass {
        case .phone: "iPhone"
        case .tablet: "iPad"
        }
    }
}
