import CryptoKit
import Foundation

@testable import StrideKit

/// The system prompt, replaced: it answers from a script and signs with the
/// software key the example keys hold.
actor FakeUnlocker: ApprovalKeyUnlocking {
    struct Use: Equatable {
        let message: Data
        let publicKey: String
        let reason: String
    }

    private var enrolment: BiometryState
    private var refusals: [ApprovalUnlockError]
    private(set) var uses: [Use] = []

    /// Refuses once for each of `refusals`, in order, then signs.
    init(biometry: BiometryState = .none, refusals: [ApprovalUnlockError] = []) {
        enrolment = biometry
        self.refusals = refusals
    }

    func biometry() async -> BiometryState { enrolment }

    func sign(_ message: Data, with key: ApprovalKey, reason: String) async throws(ApprovalUnlockError) -> Data {
        uses.append(Use(message: message, publicKey: key.publicKey, reason: reason))
        if refusals.isEmpty == false { throw refusals.removeFirst() }

        guard let privateKey = try? P256.Signing.PrivateKey(rawRepresentation: key.handle),
              let signature = try? privateKey.signature(for: message)
        else { throw .keyUnusable }

        return signature.derRepresentation
    }
}

/// A new sign-in, replaced: it keeps a new example key, made under `biometry`,
/// with a new pair.
actor FakeRegistrar: ApprovalKeyRegistering {
    enum Answer {
        case registers
        case stops
        case keepsNothing
        case fails(SignInError)
    }

    private let store: AuthStore
    private let answer: Answer
    private let biometry: BiometryState
    private let events: Events?
    private(set) var keys: [ApprovalKey] = []

    init(store: AuthStore, answer: Answer = .registers, biometry: BiometryState = .none, events: Events? = nil) {
        self.store = store
        self.answer = answer
        self.biometry = biometry
        self.events = events
    }

    func registerNewKey() async throws(SignInError) -> Bool {
        await events?.record("register")
        switch answer {
        case .registers:
            let key = ApprovalKey.example(biometry: biometry)
            keys.append(key)
            do {
                try await store.save(.example(keys.count + 1), approvalKey: key)
            } catch {
                throw .failed
            }
            return true
        case .stops:
            return false
        case .keepsNothing:
            return true
        case .fails(let error):
            throw error
        }
    }
}

/// The order things happened in, across the fakes.
actor Events {
    private(set) var names: [String] = []

    func record(_ name: String) {
        names.append(name)
    }
}

extension Components.Schemas.ApprovalChallenge {
    /// The nonce shape the server issues: sdan_ and 43 base64url characters.
    static let exampleNonce = "sdan_" + String(repeating: "A", count: 43)

    static func example(
        nonce: String = exampleNonce,
        taskID: Int = 8597,
        reviewRequestedAt: String = "2026-11-18T09:30:00Z"
    ) -> Self {
        Self(
            nonce: nonce,
            expiresAt: Date(timeIntervalSince1970: 1_800_000_120),
            taskId: taskID,
            reviewRequestedAt: reviewRequestedAt,
            decision: .approve,
            signingVersion: .strideApprovalV1
        )
    }
}
