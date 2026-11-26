import Foundation

/// Pages of the Stride web app that the app opens in the browser. Neither is one
/// the app's associated domains claim, so each opens outside the app.
public enum StrideWeb {
    public static let signUp = StrideClient.serverURL.appending(path: "users/register")
    public static let pricing = StrideClient.serverURL.appending(path: "pricing")
}
