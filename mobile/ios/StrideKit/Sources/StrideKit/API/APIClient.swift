import Foundation
import OpenAPIRuntime

/// Makes the client the app talks to the server with. On top of `StrideClient`
/// it reports the app's version with every request, sends the device's access
/// token, refreshes it once when the server refuses it, and tells `update` when
/// the server refuses this version of the app.
///
/// Only the app uses it, and makes one: a refresh writes to `AuthStore`, which an
/// extension must not do, and two clients would refresh the same token twice.
///
/// A call throws a `ClientError` whose `underlyingError` is the reason. That is an
/// `APIClientError`, an `AuthStoreError`, or a `URLError` when the server could not
/// be reached, and another error when the call was cancelled or its answer could
/// not be decoded.
public enum APIClient {
    public static func make(
        version: AppVersion,
        store: AuthStore,
        update: AppUpdateState
    ) -> some StrideAPI {
        make(
            transport: StrideClient.makeTransport(),
            version: version,
            store: store,
            update: update,
            readRetryDelay: .milliseconds(500)
        )
    }

    static func make(
        transport: any ClientTransport,
        version: AppVersion,
        store: AuthStore,
        update: AppUpdateState,
        readRetryDelay: Duration,
        now: @escaping @Sendable () -> Date = { .now }
    ) -> some StrideAPI {
        let everyRequest: [any ClientMiddleware] = [
            AppVersionMiddleware(version: version),
            UpdateRequiredMiddleware(update: update)
        ]
        let refresher = RefreshCoordinator(
            store: store,
            api: StrideClient.make(transport: transport, middlewares: everyRequest),
            now: now
        )

        // The first is the outermost. The read retry is inside the auth, so it
        // repeats one request and never a refresh, which must not be sent twice.
        return StrideClient.make(
            transport: transport,
            middlewares: everyRequest + [
                AuthMiddleware(refresher: refresher),
                ReadRetryMiddleware(delay: readRetryDelay)
            ]
        )
    }
}
