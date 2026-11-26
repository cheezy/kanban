import Foundation
import Security
import StrideKit
import Testing

@testable import Stride

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SignInModelTests {
    private let phone = DeviceDetails(name: "Pat's iPhone", deviceClass: .phone)

    private func model(
        store: MemorySignInStore = MemorySignInStore(),
        api: FixtureAPI = FixtureAPI(),
        keyMaker: StubApprovalKeyMaker = StubApprovalKeyMaker(),
        unlock: ApprovalUnlock = .faceID,
        phase: SignInPhase = .signedOut(nil),
        cache: RecordingCacheWiper? = nil
    ) -> SignInModel {
        SignInModel(
            services: SignInServices(store: store, api: api.client, keyMaker: keyMaker, device: phone, cache: cache),
            unlock: unlock,
            phase: phase,
            retryDelay: .milliseconds(1)
        )
    }

    // MARK: Signing in

    @Test("a completed flow stores tokens and loads me")
    func completedFlow() async throws {
        let store = MemorySignInStore()
        let model = model(store: store)
        let web = StubWebAuthenticator(outcome: .allow)

        await model.signIn(using: web)

        #expect(model.phase == .signedIn(.unlocked))
        let saved = try #require(await store.saved.first)
        #expect(await store.saved.count == 1)
        #expect(saved.accessToken == "EXAMPLE-access-token-for-previews-only")
        #expect(saved.refreshToken == "EXAMPLE-refresh-token-for-previews-only")
        #expect(await store.savedKeys.count == 1)
        #expect(web.opened.count == 1)
    }

    @Test("opens the authorize page with this attempt's challenge and the device's name")
    func opensAuthorizePage() async throws {
        let web = StubWebAuthenticator(outcome: .allow)

        await model().signIn(using: web)

        let url = try #require(web.opened.first)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(url.host() == "www.stridelikeaboss.com")
        #expect(query.contains(URLQueryItem(name: "device_name", value: "Pat's iPhone")))
        #expect(query.contains(URLQueryItem(name: "code_challenge_method", value: "S256")))
    }

    @Test("the state parameter must match")
    func stateMustMatch() async {
        let store = MemorySignInStore()
        let model = model(store: store)

        await model.signIn(using: StubWebAuthenticator(outcome: .otherState))

        #expect(model.phase == .signedOut(.failed))
        #expect(model.problem?.key == "sign_in_failed")
        #expect(await store.saved.isEmpty)
    }

    @Test(
        "cancel returns to the screen with no error",
        arguments: [StubWebAuthenticator.Outcome.cancel, .deny]
    )
    func cancel(outcome: StubWebAuthenticator.Outcome) async {
        let store = MemorySignInStore()
        let model = model(store: store)

        await model.signIn(using: StubWebAuthenticator(outcome: outcome))

        #expect(model.phase == .signedOut(nil))
        #expect(model.problem == nil)
        #expect(await store.saved.isEmpty)
    }

    @Test("a network error shows the retry message")
    func networkError() async {
        let model = model(api: FixtureAPI(unreachable: [Operations.OauthToken.id]))

        await model.signIn(using: StubWebAuthenticator(outcome: .allow))

        #expect(model.phase == .signedOut(.network))
        #expect(model.problem?.key == "sign_in_network_error")
    }

    @Test("a person without the Organization plan sees the locked panel")
    func locked() async throws {
        let store = MemorySignInStore()
        let model = model(store: store, api: FixtureAPI(replacing: try FixtureAPI.lockedPlan))

        await model.signIn(using: StubWebAuthenticator(outcome: .allow))

        #expect(model.phase == .locked)
        // Locked keeps the sign-in, so joining an Organization needs no new one.
        #expect(await store.saved.count == 1)
    }

    @Test("each attempt sends a new state and challenge")
    func freshAttempt() async throws {
        let model = model(api: FixtureAPI(unreachable: [Operations.OauthToken.id]))
        let web = StubWebAuthenticator(outcome: .allow)

        await model.signIn(using: web)
        await model.signIn(using: web)

        #expect(web.opened.count == 2)
        let queries = try web.opened.map { url in
            try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        }
        for name in ["state", "code_challenge"] {
            let values = queries.map { $0.first { $0.name == name }?.value }
            #expect(values[0] != values[1], "\(name)")
        }
    }

    @Test("a device without a passcode is told so, before the browser opens")
    func passcodeNotSet() async {
        let model = model(keyMaker: StubApprovalKeyMaker(failure: .passcodeNotSet))
        let web = StubWebAuthenticator(outcome: .allow)

        await model.signIn(using: web)

        #expect(model.phase == .signedOut(.passcodeNotSet))
        #expect(model.problem?.key == "sign_in_passcode_required")
        #expect(web.opened.isEmpty)
    }

    @Test("a Keychain that refuses the sign-in fails it")
    func saveRefused() async {
        let model = model(store: MemorySignInStore(refusal: .keychain(errSecInteractionNotAllowed)))

        await model.signIn(using: StubWebAuthenticator(outcome: .allow))

        #expect(model.phase == .signedOut(.failed))
    }

    @Test("when me cannot be loaded the device stays signed in")
    func meUnavailable() async {
        let store = MemorySignInStore()
        let model = model(store: store, api: FixtureAPI(unreachable: [Operations.GetMe.id]))

        await model.signIn(using: StubWebAuthenticator(outcome: .allow))

        #expect(model.phase == .signedIn(.unknown))
        #expect(await store.saved.count == 1)
    }

    @Test("a second press while signing in opens nothing", arguments: [SignInPhase.signingIn, .locked, .starting])
    func ignoredPress(phase: SignInPhase) async {
        let model = model(phase: phase)
        let web = StubWebAuthenticator(outcome: .allow)

        await model.signIn(using: web)

        #expect(model.phase == phase)
        #expect(web.opened.isEmpty)
    }

    @Test("without services every attempt fails")
    func noServices() async {
        let model = SignInModel(services: nil, unlock: .faceID, phase: .signedOut(nil))
        let web = StubWebAuthenticator(outcome: .allow)

        await model.signIn(using: web)

        #expect(model.phase == .signedOut(.failed))
        #expect(web.opened.isEmpty)
    }

    // MARK: Following the stored sign-in

    @Test("a device with no stored sign-in shows the Sign in screen")
    func startsSignedOut() async {
        let model = model(phase: .starting)
        let task = Task { await model.observeSignIn() }
        defer { task.cancel() }

        await waitUntil { model.phase == .signedOut(nil) }
    }

    @Test(
        "a stored sign-in skips the screen and asks whether the plan includes the app",
        arguments: [(false, SignInPhase.signedIn(.unlocked)), (true, .locked)]
    )
    func startsSignedIn(lockedPlan: Bool, expected: SignInPhase) async throws {
        let api = lockedPlan ? FixtureAPI(replacing: try FixtureAPI.lockedPlan) : FixtureAPI()
        let model = model(store: MemorySignInStore(signedIn: true), api: api, phase: .starting)
        let task = Task { await model.observeSignIn() }
        defer { task.cancel() }

        await waitUntil { model.phase == expected }
    }

    @Test("signing out anywhere returns to the Sign in screen")
    func signOut() async {
        let store = MemorySignInStore(signedIn: true)
        let model = model(store: store, phase: .starting)
        let task = Task { await model.observeSignIn() }
        defer { task.cancel() }
        await waitUntil { model.phase == .signedIn(.unlocked) }

        await store.clear()

        await waitUntil { model.phase == .signedOut(nil) }
    }

    @Test("signing out wipes the cache")
    func signOutWipesCache() async {
        let store = MemorySignInStore(signedIn: true)
        let cache = RecordingCacheWiper()
        let model = model(store: store, phase: .starting, cache: cache)
        let task = Task { await model.observeSignIn() }
        defer { task.cancel() }
        await waitUntil { model.phase == .signedIn(.unlocked) }
        #expect(await cache.wipes == 0)

        await store.clear()

        await waitUntil { model.phase == .signedOut(nil) }
        #expect(await cache.wipes == 1)
    }

    @Test("starting signed out wipes the cache")
    func startSignedOutWipesCache() async {
        let cache = RecordingCacheWiper()
        let model = model(phase: .starting, cache: cache)
        let task = Task { await model.observeSignIn() }
        defer { task.cancel() }

        await waitUntil { model.phase == .signedOut(nil) }
        #expect(await cache.wipes == 1)
    }

    @Test("signing in leaves the cache")
    func signInKeepsCache() async {
        let store = MemorySignInStore()
        let cache = RecordingCacheWiper()
        let model = model(store: store, phase: .starting, cache: cache)
        let task = Task { await model.observeSignIn() }
        defer { task.cancel() }
        await waitUntil { model.phase == .signedOut(nil) }

        await model.signIn(using: StubWebAuthenticator(outcome: .allow))

        await waitUntil { model.phase == .signedIn(.unlocked) }
        #expect(await cache.wipes == 1)
    }

    @Test("without services the Sign in screen shows at once")
    func observeWithoutServices() async {
        let model = SignInModel(services: nil, unlock: .faceID)

        await model.observeSignIn()

        #expect(model.phase == .signedOut(nil))
    }

    @Test("asks the Keychain again until it answers, and stops when the screen goes")
    func keychainLocked() async {
        let model = model(store: MemorySignInStore(refusal: .keychain(errSecInteractionNotAllowed)), phase: .starting)
        let task = Task { await model.observeSignIn() }

        for _ in 0..<20 { await Task.yield() }
        #expect(model.phase == .starting)

        task.cancel()
        await task.value
        #expect(model.phase == .starting)
    }

    // MARK: Asking again

    @Test("a locked person who joined an Organization gets in when the app comes back")
    func recheckUnlocks() async {
        let model = model(phase: .locked)

        await model.recheckAccess()

        #expect(model.phase == .signedIn(.unlocked))
    }

    @Test("an unknown answer is asked again")
    func recheckUnknown() async {
        let model = model(phase: .signedIn(.unknown))

        await model.recheckAccess()

        #expect(model.phase == .signedIn(.unlocked))
    }

    @Test(
        "asks nothing on the Sign in screen or once the app is unlocked",
        arguments: [SignInPhase.signedIn(.unlocked), .signedOut(nil), .starting, .signingIn]
    )
    func recheckNothing(phase: SignInPhase) async throws {
        let model = model(api: FixtureAPI(replacing: try FixtureAPI.lockedPlan), phase: phase)

        await model.recheckAccess()

        #expect(model.phase == phase)
    }

    // MARK: What the screen says

    @Test(
        "the first point names what the person approves with",
        arguments: [
            (ApprovalUnlock.faceID, "sign_in_point_review_face_id"),
            (.touchID, "sign_in_point_review_touch_id"),
            (.passcode, "sign_in_point_review_passcode")
        ]
    )
    func reviewPoint(unlock: ApprovalUnlock, key: String) {
        #expect(model(unlock: unlock).reviewPoint.key == key)
    }

    @Test("the button shows progress only while signing in")
    func isSigningIn() {
        #expect(model(phase: .signingIn).isSigningIn)
        #expect(model(phase: .signedOut(nil)).isSigningIn == false)
        #expect(model(phase: .signedOut(.network)).problem != nil)
        #expect(model(phase: .locked).problem == nil)
    }

    /// Lets the model's task run until `condition` holds.
    private func waitUntil(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<2_000 where condition() == false {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), sourceLocation: sourceLocation)
    }
}
