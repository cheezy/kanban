import Foundation

extension LocalizedStringResource {
    /// The string in `locale`, so a view shows it in the locale of its
    /// environment, as a preview or a test in another language sets it, and not
    /// only in the device's.
    func resolved(in locale: Locale) -> String {
        var resource = self
        resource.locale = locale

        return String(localized: resource)
    }
}
