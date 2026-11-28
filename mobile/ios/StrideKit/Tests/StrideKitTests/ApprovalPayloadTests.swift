import CryptoKit
import CryptoTokenKit
import Foundation
import LocalAuthentication
import Testing

@testable import StrideKit

struct ApprovalPayloadTests {
    @Test("is the server's five lines, joined by a line feed, with none at the end")
    func signingString() throws {
        let payload = try ApprovalPayload(.example())

        #expect(
            payload.signingString
                == "stride-approval-v1\n\(Components.Schemas.ApprovalChallenge.exampleNonce)\n8597\n2026-11-18T09:30:00Z\napprove"
        )
        #expect(payload.message == Data(payload.signingString.utf8))
    }

    @Test("matches the example the API contract gives")
    func contractExample() throws {
        let payload = try ApprovalPayload(
            nonce: "sdan_EXAMPLE0nonce0value0only0for0documentation0",
            taskID: 4812,
            reviewRequestedAt: "2026-11-18T09:30:00Z"
        )

        #expect(
            payload.signingString
                == "stride-approval-v1\nsdan_EXAMPLE0nonce0value0only0for0documentation0\n4812\n2026-11-18T09:30:00Z\napprove"
        )
    }

    @Test("a task without review_requested_at signs an empty line")
    func noReviewRequestedAt() throws {
        let payload = try ApprovalPayload(.example(taskID: 1, reviewRequestedAt: ""))

        #expect(payload.signingString == "stride-approval-v1\n\(Components.Schemas.ApprovalChallenge.exampleNonce)\n1\n\napprove")
    }

    @Test("signs review_requested_at as the server spelled it")
    func verbatim() throws {
        let payload = try ApprovalPayload(.example(reviewRequestedAt: "2026-11-18T09:30:00.000000Z"))

        #expect(payload.reviewRequestedAt == "2026-11-18T09:30:00.000000Z")
    }

    @Test("refuses a value that could change the lines", arguments: [
        ("", 1, ""),
        ("sdan_A\napprove", 1, ""),
        ("sdan_A=", 1, ""),
        ("sdan A", 1, ""),
        ("sdan_A", 0, ""),
        ("sdan_A", -1, ""),
        ("sdan_A", 1, "2026-11-18T09:30:00Z\napprove"),
        ("sdan_A", 1, "2026-11-18T09:30:00Z\r")
    ])
    func refuses(nonce: String, taskID: Int, reviewRequestedAt: String) {
        #expect(throws: ApprovalSignerError.invalidChallenge) {
            try ApprovalPayload(nonce: nonce, taskID: taskID, reviewRequestedAt: reviewRequestedAt)
        }
    }

    @Test("prints, dumps and reflects as redacted")
    func redacted() throws {
        let payload = try ApprovalPayload(.example())
        var dumped = ""
        dump(payload, to: &dumped)

        #expect(String(describing: payload) == "ApprovalPayload(redacted)")
        #expect(String(reflecting: payload) == "ApprovalPayload(redacted)")
        #expect(dumped.contains(payload.nonce) == false)
        #expect(Mirror(reflecting: payload).children.isEmpty)
    }
}

struct BiometryStateTests {
    @Test("a different enrolment, or one added or removed, is a change", arguments: [
        (BiometryState.enrolled(Data([1])), BiometryState.enrolled(Data([2]))),
        (.none, .enrolled(Data([1]))),
        (.enrolled(Data([1])), .none)
    ])
    func changed(earlier: BiometryState, now: BiometryState) {
        #expect(now.changed(since: earlier))
    }

    @Test("the same enrolment, or an unknown one on either side, is no change", arguments: [
        (BiometryState.enrolled(Data([1])), BiometryState.enrolled(Data([1]))),
        (.none, .none),
        (.unknown, .unknown),
        (.unknown, .enrolled(Data([1]))),
        (.enrolled(Data([1])), .unknown),
        (.none, .unknown)
    ])
    func unchanged(earlier: BiometryState, now: BiometryState) {
        #expect(now.changed(since: earlier) == false)
    }

    @Test("only nothing enrolled is a state when biometrics cannot be used")
    func unavailable() {
        #expect(BiometryState(unavailable: LAError.biometryNotEnrolled.rawValue) == .none)
        #expect(BiometryState(unavailable: LAError.biometryNotAvailable.rawValue) == .unknown)
        #expect(BiometryState(unavailable: LAError.biometryLockout.rawValue) == .unknown)
        #expect(BiometryState(unavailable: nil) == .unknown)
    }

    @Test("a hash is the enrolment, and no hash is unknown")
    func hash() {
        #expect(BiometryState(hash: Data([7])) == .enrolled(Data([7])))
        #expect(BiometryState(hash: nil) == .unknown)
    }
}

struct ApprovalUnlockErrorTests {
    @Test("closing the prompt is cancelled", arguments: [
        LAError.Code.userCancel, .systemCancel, .appCancel, .userFallback
    ])
    func cancelled(code: LAError.Code) {
        #expect(ApprovalUnlockError(LAError(code)) == .cancelled)
    }

    @Test("no passcode is its own error")
    func passcode() {
        #expect(ApprovalUnlockError(LAError(.passcodeNotSet)) == .passcodeNotSet)
    }

    @Test("anything else failed", arguments: [
        LAError.Code.authenticationFailed, .notInteractive, .biometryLockout, .invalidContext
    ])
    func failed(code: LAError.Code) {
        #expect(ApprovalUnlockError(LAError(code)) == .failed)
    }

    @Test("a cancelled task is cancelled too")
    func cancelledTask() {
        #expect(ApprovalUnlockError(CancellationError()) == .cancelled)
    }

    @Test("closing the enclave's own sheet while opening the key is cancelled", arguments: [
        LAError.Code.userCancel, .systemCancel, .appCancel, .userFallback
    ])
    func keyCancelled(code: LAError.Code) {
        #expect(ApprovalUnlockError(keyError: LAError(code)) == .cancelled)
        #expect(ApprovalUnlockError(keyError: CancellationError()) == .cancelled)
    }

    @Test("the enclave sheet's cancel from CryptoTokenKit is cancelled too")
    func keyTokenCancelled() {
        #expect(ApprovalUnlockError(keyError: TKError(.canceledByUser)) == .cancelled)
    }

    @Test("an unlock the enclave no longer accepts failed, and leaves the key alone")
    func keyInvalidContext() {
        #expect(ApprovalUnlockError(keyError: LAError(.invalidContext)) == .failed)
    }

    @Test("no passcode while opening the key is its own error")
    func keyPasscode() {
        #expect(ApprovalUnlockError(keyError: LAError(.passcodeNotSet)) == .passcodeNotSet)
    }

    @Test("any other error opening the key means it is unusable")
    func keyUnusable() {
        #expect(ApprovalUnlockError(keyError: LAError(.authenticationFailed)) == .keyUnusable)
        #expect(ApprovalUnlockError(keyError: TKError(.corruptedData)) == .keyUnusable)
        #expect(ApprovalUnlockError(keyError: CryptoKitError.incorrectKeySize) == .keyUnusable)
        #expect(ApprovalUnlockError(keyError: URLError(.unknown)) == .keyUnusable)
    }
}
