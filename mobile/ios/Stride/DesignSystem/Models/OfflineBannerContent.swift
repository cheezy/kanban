import Foundation

/// What the offline banner says: when the shown data was fetched.
struct OfflineBannerContent: Hashable, Sendable {
    let fetchedAt: Date

    /// Such as "Offline · showing what you had at 9:41 AM", in the reader's
    /// locale and time zone.
    func message(in locale: Locale, timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.locale = locale
        style.timeZone = timeZone

        return LocalizedStringResource.offlineBanner(time: fetchedAt.formatted(style)).resolved(in: locale)
    }
}
