import Foundation

extension Duration {
    /// How long a hook ran, as the card and the attempt say it: "4s",
    /// "1m 12s", in `locale`.
    func hookText(in locale: Locale) -> String {
        let style = Duration.UnitsFormatStyle(
            allowedUnits: [.hours, .minutes, .seconds],
            width: .narrow,
            maximumUnitCount: 2
        )
        return formatted(style.locale(locale))
    }
}
