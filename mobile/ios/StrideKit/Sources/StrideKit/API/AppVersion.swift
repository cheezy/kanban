import Foundation

/// The version and build of the app, in the form the server reads: `ios/1.0.0 (42)`.
///
/// The server tells from it whether this version may still be used, and ignores
/// a value it cannot read.
public struct AppVersion: Equatable, Sendable {
    let headerValue: String

    /// Returns nil when the server could not read the version or the build.
    public init?(version: String, build: String) {
        guard
            version.wholeMatch(of: /[0-9]{1,4}(\.[0-9]{1,4}){2}/) != nil,
            build.wholeMatch(of: /[0-9]{1,9}/) != nil
        else { return nil }

        headerValue = "ios/\(version) (\(build))"
    }

    public init?(bundle: Bundle) {
        guard
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        else { return nil }

        self.init(version: version, build: build)
    }
}
