import Foundation

/// Reads the store page from the server's answer to an outdated app.
enum AppStoreLink {
    static let fallback = URL(string: "https://apps.apple.com/app/stride")!

    private static let hosts = ["apps.apple.com", "testflight.apple.com"]

    /// The page the answer names, when it is one of Apple's, so that the answer
    /// cannot send the person anywhere else.
    static func url(in answer: Data?) -> URL {
        guard
            let answer,
            let update = try? JSONDecoder().decode(Components.Schemas.AppUpdateRequired.self, from: answer),
            let url = URL(string: update.storeUrl),
            url.scheme == "https",
            let host = url.host(),
            hosts.contains(host),
            url.user() == nil, url.password() == nil, url.port == nil
        else { return fallback }

        return url
    }
}
