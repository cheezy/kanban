import CryptoKit
import Foundation
import Testing

@testable import StrideKit

@Suite(.timeLimit(.minutes(1)))
struct ApprovalSignerTests {
    private static let reason = "Approve W2701"

    /// The signing string `Kanban.Reviews.ApprovalSignature` builds for the
    /// example challenge (test/kanban/reviews/approval_test.exs).
    private static let expected =
        "stride-approval-v1\n\(Components.Schemas.ApprovalChallenge.exampleNonce)\n8597\n2026-11-18T09:30:00Z\napprove"

    private let container: TemporaryDirectory
    private let store: AuthStore

    init() throws {
        container = try TemporaryDirectory()
        let marker = InstallMarker(container: container.url)
        try marker.create()
        store = AuthStore(accessGroup: "TEAM.example.shared", marker: marker, keychain: FakeKeychain())
    }

    @Test("signs the canonical payload the server expects")
    func canonical() async throws {
        let key = try await signedIn()
        let unlocker = FakeUnlocker()

        let outcome = try await signer(unlocker).sign(reason: Self.reason) { .example() }

        let signed = try #require(signed(outcome))
        #expect(signed.taskID == 8597)
        #expect(signed.nonce == Components.Schemas.ApprovalChallenge.exampleNonce)
        #expect(signed.reviewRequestedAt == "2026-11-18T09:30:00Z")
        #expect(await unlocker.uses.map(\.message) == [Data(Self.expected.utf8)])
        #expect(try verifies(signed, Self.expected, key))
    }

    @Test("the signature is DER in unpadded base64url, never the raw r and s")
    func signatureEncoding() async throws {
        _ = try await signedIn()

        let outcome = try await signer(FakeUnlocker()).sign(reason: Self.reason) { .example() }

        let signature = try #require(signed(outcome)).signature
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(signature.unicodeScalars.allSatisfy(allowed.contains))
        let bytes = try #require(Data(base64URLEncoded: signature))
        #expect(bytes.first == 0x30)
        #expect(throws: Never.self) { try P256.Signing.ECDSASignature(derRepresentation: bytes) }
    }

    @Test("asks with the reason it is given")
    func reason() async throws {
        _ = try await signedIn()
        let unlocker = FakeUnlocker()

        _ = try await signer(unlocker).sign(reason: Self.reason) { .example() }

        #expect(await unlocker.uses.map(\.reason) == [Self.reason])
    }

    @Test("a cancelled biometric returns cancelled, not an error")
    func cancelled() async throws {
        _ = try await signedIn()
        let registrar = FakeRegistrar(store: store)

        let outcome = try await signer(FakeUnlocker(refusals: [.cancelled]), registrar).sign(reason: Self.reason) {
            .example()
        }

        #expect(outcome == .cancelled)
        #expect(await registrar.keys.isEmpty)
    }

    @Test("changed biometrics recreate and re-register the key")
    func changedBiometrics() async throws {
        let old = try await signedIn(biometry: .enrolled(Data([1])))
        let events = Events()
        let unlocker = FakeUnlocker(biometry: .enrolled(Data([2])))
        let registrar = FakeRegistrar(store: store, biometry: .enrolled(Data([2])), events: events)

        let outcome = try await signer(unlocker, registrar).sign(reason: Self.reason) {
            await events.record("challenge")
            return .example()
        }

        let new = try #require(await registrar.keys.first)
        #expect(await registrar.keys.count == 1)
        #expect(await events.names == ["register", "challenge"])
        #expect(await unlocker.uses.map(\.publicKey) == [new.publicKey])
        #expect(try await store.approvalKey() == new)
        let result = try #require(signed(outcome))
        #expect(try verifies(result, Self.expected, new))
        #expect(try verifies(result, Self.expected, old) == false)
    }

    @Test("an unchanged enrolment keeps the key", arguments: [
        (BiometryState.enrolled(Data([1])), BiometryState.enrolled(Data([1]))),
        (.none, .none),
        (.enrolled(Data([1])), .unknown),
        (.unknown, .enrolled(Data([1])))
    ])
    func unchangedBiometrics(made: BiometryState, now: BiometryState) async throws {
        let key = try await signedIn(biometry: made)
        let registrar = FakeRegistrar(store: store)

        let outcome = try await signer(FakeUnlocker(biometry: now), registrar).sign(reason: Self.reason) {
            .example()
        }

        #expect(await registrar.keys.isEmpty)
        let result = try #require(signed(outcome))
        #expect(try verifies(result, Self.expected, key))
    }

    @Test("no key yet registers one before signing")
    func noKey() async throws {
        let events = Events()
        let registrar = FakeRegistrar(store: store, events: events)
        let unlocker = FakeUnlocker()

        let outcome = try await signer(unlocker, registrar).sign(reason: Self.reason) {
            await events.record("challenge")
            return .example()
        }

        let new = try #require(await registrar.keys.first)
        #expect(await events.names == ["register", "challenge"])
        #expect(await unlocker.uses.map(\.publicKey) == [new.publicKey])
        let result = try #require(signed(outcome))
        #expect(try verifies(result, Self.expected, new))
    }

    @Test("a key the enclave refuses is replaced, and a new challenge signed with the new one")
    func refusedKey() async throws {
        _ = try await signedIn()
        let events = Events()
        let unlocker = FakeUnlocker(refusals: [.keyUnusable])
        let registrar = FakeRegistrar(store: store, events: events)

        let outcome = try await signer(unlocker, registrar).sign(reason: Self.reason) {
            await events.record("challenge")
            return .example()
        }

        let new = try #require(await registrar.keys.first)
        #expect(await events.names == ["challenge", "register", "challenge"])
        let result = try #require(signed(outcome))
        #expect(try verifies(result, Self.expected, new))
    }

    @Test("a new key the enclave refuses too is an error, after one new sign-in")
    func refusedTwice() async throws {
        _ = try await signedIn()
        let registrar = FakeRegistrar(store: store)

        await #expect(throws: ApprovalSignerError.keyUnusable) {
            try await signer(FakeUnlocker(refusals: [.keyUnusable, .keyUnusable]), registrar)
                .sign(reason: Self.reason) { .example() }
        }
        #expect(await registrar.keys.count == 1)
    }

    /// With a stored key, the enrolment has changed since it was made; without
    /// one, there is no key yet. Either way the signer makes a key first.
    @Test("a key just made that the enclave refuses is an error, never a second sign-in", arguments: [true, false])
    func refusedNewKey(hadKey: Bool) async throws {
        if hadKey { _ = try await signedIn(biometry: .enrolled(Data([1]))) }
        let now = BiometryState.enrolled(Data([2]))
        let registrar = FakeRegistrar(store: store, biometry: now)
        let unlocker = FakeUnlocker(biometry: now, refusals: [.keyUnusable])

        await #expect(throws: ApprovalSignerError.keyUnusable) {
            try await signer(unlocker, registrar).sign(reason: Self.reason) { .example() }
        }
        #expect(await registrar.keys.count == 1)
        #expect(await unlocker.uses.count == 1)
    }

    @Test("stopping the sign-in a new key needs is cancelled", arguments: [
        FakeRegistrar.Answer.stops,
        .fails(.cancelled)
    ])
    func stoppedSignIn(answer: FakeRegistrar.Answer) async throws {
        let unlocker = FakeUnlocker()

        let outcome = try await signer(unlocker, FakeRegistrar(store: store, answer: answer))
            .sign(reason: Self.reason) { .example() }

        #expect(outcome == .cancelled)
        #expect(await unlocker.uses.isEmpty)
    }

    @Test("a failed sign-in is the sign-in's error")
    func failedSignIn() async throws {
        await #expect(throws: ApprovalSignerError.signIn(.network)) {
            try await signer(FakeUnlocker(), FakeRegistrar(store: store, answer: .fails(.network)))
                .sign(reason: Self.reason) { .example() }
        }
    }

    @Test("a sign-in that keeps no key is an error")
    func keptNothing() async throws {
        await #expect(throws: ApprovalSignerError.keyUnavailable) {
            try await signer(FakeUnlocker(), FakeRegistrar(store: store, answer: .keepsNothing))
                .sign(reason: Self.reason) { .example() }
        }
    }

    @Test("a refused prompt is an error", arguments: [
        (ApprovalUnlockError.passcodeNotSet, ApprovalSignerError.passcodeNotSet),
        (.failed, .failed)
    ])
    func refusedPrompt(refusal: ApprovalUnlockError, error: ApprovalSignerError) async throws {
        _ = try await signedIn()

        await #expect(throws: error) {
            try await signer(FakeUnlocker(refusals: [refusal])).sign(reason: Self.reason) { .example() }
        }
    }

    @Test("an error fetching the challenge is passed on unchanged, and nothing is asked")
    func challengeError() async throws {
        _ = try await signedIn()
        let unlocker = FakeUnlocker()

        await #expect(throws: URLError(.notConnectedToInternet)) {
            try await signer(unlocker).sign(reason: Self.reason) { throw URLError(.notConnectedToInternet) }
        }
        #expect(await unlocker.uses.isEmpty)
    }

    @Test("a challenge the signing string cannot carry is refused before anything is asked")
    func invalidChallenge() async throws {
        _ = try await signedIn()
        let unlocker = FakeUnlocker()

        await #expect(throws: ApprovalSignerError.invalidChallenge) {
            try await signer(unlocker).sign(reason: Self.reason) { .example(nonce: "sdan_A\napprove") }
        }
        #expect(await unlocker.uses.isEmpty)
    }

    #if targetEnvironment(simulator)
    @Test("the simulator's unlocker signs with the software key")
    func simulatorUnlocker() async throws {
        let key = ApprovalKey.example()
        let message = Data(Self.expected.utf8)

        let der = try await SecureEnclaveUnlocker().sign(message, with: key, reason: Self.reason)

        let point = try #require(Data(base64URLEncoded: key.publicKey))
        let publicKey = try P256.Signing.PublicKey(x963Representation: point)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: der)
        #expect(publicKey.isValidSignature(signature, for: message))
    }

    @Test("the simulator's unlocker refuses a handle that is not a key")
    func simulatorUnlockerRefuses() async throws {
        let key = ApprovalKey(publicKey: ApprovalKey.example().publicKey, handle: Data([1, 2, 3]), biometry: .none)

        await #expect(throws: ApprovalUnlockError.keyUnusable) {
            try await SecureEnclaveUnlocker().sign(Data(), with: key, reason: Self.reason)
        }
    }
    #endif

    @Test("prints, dumps and reflects a signed approval as redacted")
    func redacted() async throws {
        _ = try await signedIn()
        let outcome = try await signer(FakeUnlocker()).sign(reason: Self.reason) { .example() }
        let signed = try #require(signed(outcome))
        var dumped = ""
        dump(signed, to: &dumped)

        #expect(String(describing: signed) == "SignedApproval(redacted)")
        #expect(String(reflecting: signed) == "SignedApproval(redacted)")
        #expect(String(describing: outcome).contains(signed.signature) == false)
        #expect(dumped.contains(signed.signature) == false)
        #expect(dumped.contains(signed.nonce) == false)
        #expect(Mirror(reflecting: signed).children.isEmpty)
    }

    private func signedIn(biometry: BiometryState = .none) async throws -> ApprovalKey {
        let key = ApprovalKey.example(biometry: biometry)
        try await store.save(.example(), approvalKey: key)
        return key
    }

    private func signer(
        _ unlocker: FakeUnlocker,
        _ registrar: FakeRegistrar? = nil
    ) -> ApprovalSigner {
        ApprovalSigner(store: store, registrar: registrar ?? FakeRegistrar(store: store), unlocker: unlocker)
    }

    private func signed(_ outcome: ApprovalSigner.Outcome) -> SignedApproval? {
        guard case .signed(let signed) = outcome else { return nil }
        return signed
    }

    /// Whether the signature checks out as the server checks it: DER ECDSA
    /// P-256 over SHA-256 of `string`, against the registered public key.
    private func verifies(_ signed: SignedApproval, _ string: String, _ key: ApprovalKey) throws -> Bool {
        let point = try #require(Data(base64URLEncoded: key.publicKey))
        let der = try #require(Data(base64URLEncoded: signed.signature))
        let publicKey = try P256.Signing.PublicKey(x963Representation: point)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: der)
        return publicKey.isValidSignature(signature, for: Data(string.utf8))
    }
}
