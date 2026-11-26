import OpenAPIRuntime

/// Whether the signed-in person's plan includes the app.
public enum AppAccess: Equatable, Sendable {
    /// Not asked yet.
    case checking
    case unlocked
    /// The person is not in an Organization with the Organization plan.
    case locked
    /// The server could not say. The app carries on as signed in, and asks again.
    case unknown

    /// Asks the server through `GET /api/me`. A sign-in that ends meanwhile is
    /// announced by `AuthStore`, so it reads as unknown here.
    public static func load(using api: any StrideAPI) async -> AppAccess {
        guard
            case .ok(let response) = try? await api.getMe(),
            let me = try? response.body.json.data
        else { return .unknown }

        return me.appUnlocked ? .unlocked : .locked
    }
}
