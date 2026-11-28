import Foundation

/// Pages of the Stride web app that the app opens in the browser. None is one
/// the app's associated domains claim, so each opens outside the app.
public enum StrideWeb {
    public static let signUp = StrideClient.serverURL.appending(path: "users/register")
    public static let pricing = StrideClient.serverURL.appending(path: "pricing")

    /// The web's Review page with the task `taskID` selected, where a change
    /// too large to approve on a phone is approved.
    public static func review(taskID: Int) -> URL {
        StrideClient.serverURL
            .appending(path: "review")
            .appending(queryItems: [URLQueryItem(name: "task", value: String(taskID))])
    }

    /// Whether `url` is an https page on the Stride server, with no user,
    /// password or port, so that an address from the server's answer cannot
    /// send the person to another site.
    public static func isStridePage(_ url: URL) -> Bool {
        url.scheme == "https"
            && url.host() != nil
            && url.host() == StrideClient.serverURL.host()
            && url.user() == nil && url.password() == nil && url.port == nil
    }
}
