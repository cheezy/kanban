import Foundation

@testable import StrideKit

/// A device signed in with the first example pair, whose Keychain is in memory.
struct SignedInDevice {
    private let container: TemporaryDirectory
    let keychain = FakeKeychain()
    let store: AuthStore
    let update: AppUpdateState

    init() async throws {
        container = try TemporaryDirectory()
        let marker = InstallMarker(container: container.url)
        try marker.create()
        store = AuthStore(accessGroup: "TEAM.example.shared", marker: marker, keychain: keychain)
        update = await AppUpdateState()
        try await store.save(.example(1))
    }

    /// The client the app uses, talking to `server`.
    func api(
        _ server: FakeServer,
        version: String = "1.0.0",
        build: String = "42",
        readRetryDelay: Duration = .zero
    ) -> any StrideAPI {
        APIClient.make(
            transport: server,
            version: AppVersion(version: version, build: build)!,
            store: store,
            update: update,
            readRetryDelay: readRetryDelay,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
    }
}
