# iOS Approval Signer

This document is for contributors who work on the native iOS and iPadOS app in
`mobile/ios`. It describes `ApprovalSigner` in StrideKit: how the app signs an
approval with the device's approval key, what it signs, and what happens when
the key can no longer be used. The server's side is section 7.5 of the
[Phase 1 design](plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md), and section 9.3
covers the key. How the key is made at sign-in is in
[iOS Sign-in](ios-sign-in.md).

## The key

The approval key is made at sign-in, before the browser opens: a non-exportable
P-256 key in the Secure Enclave whose access control is the biometrics enrolled
now (`.biometryCurrentSet`) or the passcode, so every use asks for Face ID,
Touch ID or the passcode. Its public half goes to the server with the token
exchange (`approval_public_key` on `POST /oauth/token`), which is the only
request that carries one. `AuthStore` keeps the key beside the token pair, with
the enrolment it was made under (`BiometryState`), so signing out removes both.

The simulator has no Secure Enclave and no passcode, so there the key is a
software key and signing asks for nothing.

iOS lets the app use Face ID only when its Info.plist gives the reason
(`NSFaceIDUsageDescription`). Without it the enrolment reads as unknown and the
prompt falls back to the passcode. The reason is the `mobile` string
`info_plist_face_id_usage`: `project.yml` sets its English text and
`mix mobile.strings` writes each locale's to `Stride/Resources/InfoPlist.xcstrings`.

## What is signed

`ApprovalPayload` builds the signing string from the server's one-time
challenge (`POST /api/me/reviews/{task_id}/approval_challenge`): five lines
joined by a line feed, in UTF-8, with no line feed at the end.

```text
stride-approval-v1
<nonce>
<task id>
<review_requested_at, or nothing when the task has none>
approve
```

The values are the challenge's own, unchanged: `review_requested_at` is signed
as the server spelled it, never parsed and written again. A challenge whose
nonce is empty or not base64url, whose task id is not positive, or whose
`review_requested_at` holds a line break is refused before anything is asked,
since it could change the meaning of the lines. `Kanban.Reviews.ApprovalSignature`
builds the same string on the server.

The signature is ECDSA P-256 over SHA-256 of those bytes, DER-encoded and sent
as unpadded base64url (`SignedApproval.signature`), never the raw r and s.

## Signing

`ApprovalSigner.sign(reason:challenge:)` takes the prompt's text, which the app
gives as "Approve W2701", and a closure that fetches a challenge. In order it:

1. Reads the stored key. When there is none, or the enrolled faces or fingers
   differ from those the key was made under, it has a new key made and
   registered first, so the person is not asked to approve with a key that no
   longer matches.
2. Fetches the challenge, and refuses one the signing string cannot carry.
3. Asks for Face ID, Touch ID or the passcode with the reason, and signs with
   the context the person unlocked, so the key's own check asks no second time.
4. When the Secure Enclave refuses the key, has a new one made and registered,
   fetches a new challenge, since the old one is bound to the old key's device,
   and signs once more. A second refusal is `ApprovalSignerError.keyUnusable`,
   and so is a refusal of a key step 1 has just made: one approval asks for at
   most one new sign-in. Closing a passcode sheet the enclave shows of its own
   while it opens the key is a cancel, never a reason to replace the key.
   Neither is an unlock the enclave no longer accepts, which is
   `ApprovalSignerError.failed`.

It answers `signed` with what the approve request sends (`taskID`, `nonce`,
`reviewRequestedAt` and `signature`), or `cancelled` when the person closes the
prompt or stops the sign-in a new key needs. A cancel is never an error. An
error the challenge closure throws, such as a 409, is passed on unchanged; every
other error is an `ApprovalSignerError`, none of which holds a nonce, a key or a
signature.

## A new key means a new sign-in

`.biometryCurrentSet` ties the key to the enrolment at sign-in, and no request
after sign-in takes a public key, so a new key needs a new sign-in, as section
9.3 says. The signer asks for it through `ApprovalKeyRegistering`, which the app
implements with its sign-in flow; that flow keeps the new key with the new pair
through `AuthStore.save(_:approvalKey:)`.

The enrolment is read with `LAContext` without asking for anything: the domain
state hash (`domainState.biometry.stateHash` on iOS 18 and later,
`evaluatedPolicyDomainState` on iOS 17). An unknown state on either side, such
as a lockout or Face ID turned off for the app, is never a change, so it does
not throw a working key away. Because the key also accepts the passcode, the
Secure Enclave alone may keep using it after a new face is enrolled; the
enrolment check is what replaces it.

A key an earlier build kept as its bare handle reads as no key, so the next
approval registers a new one.

## Approving from the review screen

`ApproveFlow` in the app runs one approval for `ReviewModel`. It asks for the
challenge with the `review_fingerprint` and `review_requested_at` the screen
loaded, so a review that changed since answers 409 (Already decided or
Resubmitted) or 422 `too_large_for_phone` (the review loads again to say where
to approve it). It signs through `ApprovalSigning`, which the app implements
with `DeviceApprovalSigning` around `ApprovalSigner` and `SignInKeyRegistrar`,
the new sign-in a new key needs. Then it sends the approval with a new UUID
as its `Idempotency-Key`.

A request that never reached the server (a `URLError`, as `CallFailure.isTransport`
tells) is sent once more with the same key and the same body, so a lost answer
cannot approve twice. A second loss says the approval failed; the next tap
starts again from a new challenge, so a signature is never kept or sent late.
A `signature_rejected` answer says the challenge ran out (`expired`, `reused`)
or the device's signature was refused (`invalid`, `missing`), and Approve stays
on. Approve is off while the device is offline, while an approval is on its
way and after it went through; the toast then says which held-up tasks can
start, and Next opens the next review in the queue. Once approved, the screen
asks the server nothing more, since the review no longer waits and a refresh
would say it is gone, and `Cache.forget` drops its cached copy, so it never
reopens offline as still waiting. A load already on its way when the approval
lands is dropped too, so its answer neither hides the toast nor caches the
review again.

The generated encoder leaves out a `review_requested_at` that is nil, and the
server answers 400 when the approve body has no such key. Every task that
enters Review gets the stamp, so this only matters for a review without one.

A debug build started with `-StrideStubApproval` followed by `match`,
`nomatch` or `passcode` answers Face ID without a prompt: `match` signs the
challenge with an example signature the fixtures accept, `nomatch` closes the
prompt, and `passcode` acts as a device with no passcode, so the review shows
why it cannot approve and nothing is fetched or sent. A build signed in through
`-StrideStubSignIn` matches unless told otherwise.

## Never logged

`ApprovalPayload` and `SignedApproval` print, dump and reflect as redacted, like
`ApprovalKey` and `TokenPair`. Never log, print or snapshot the nonce, the key or
the signature, and never put one in a fixture.

## Where each part lives

| Part | File |
|---|---|
| The signer | `StrideKit/Sources/StrideKit/Approval/ApprovalSigner.swift` |
| The signing string | `StrideKit/Sources/StrideKit/Approval/ApprovalPayload.swift` |
| The prompt and the Secure Enclave | `StrideKit/Sources/StrideKit/Approval/ApprovalKeyUnlocking.swift` |
| The enrolment | `StrideKit/Sources/StrideKit/Approval/BiometryState.swift` |
| Registering a new key | `StrideKit/Sources/StrideKit/Approval/ApprovalKeyRegistering.swift` |
| What the approve request sends | `StrideKit/Sources/StrideKit/Approval/SignedApproval.swift` |
| Why it could not sign | `StrideKit/Sources/StrideKit/Approval/ApprovalSignerError.swift` |
| The key itself | `StrideKit/Sources/StrideKit/Auth/ApprovalKey.swift` |
| One approval from the review screen | `Stride/Features/Review/ApproveFlow.swift` |
| The app's signer and its new sign-in | `Stride/Features/Review/DeviceApprovalSigning.swift`, `Stride/Features/SignIn/SignInKeyRegistrar.swift` |
| The debug build's Face ID | `Stride/Debug/StubApprovalSigning.swift` |

The paths are under `mobile/ios/`.

## Tests

- `ApprovalSignerTests` checks the signature against the server's signing
  string and the registered public key, and drives every path through a fake
  prompt and a fake sign-in: a cancel, a changed and an unchanged enrolment, no
  key yet, a key the enclave refuses once and twice, a key it refuses just
  after it was made, a stopped or failed sign-in, a refused prompt, a challenge
  error and a challenge it refuses.
- `ApprovalPayloadTests` checks the signing string, the API contract's example,
  a task without `review_requested_at` and each value it refuses.
  `BiometryStateTests` and `ApprovalUnlockErrorTests` check when an enrolment is
  a change and what each `LAError` means, from the prompt and from opening the
  key. `LocalizationTests` checks Face ID's reason in the Info.plist and in
  every locale.
- `ApproveFlowTests` drives Approve through the fixtures: an approval and its
  toast, what the challenge and the approval carry, the one resend with the
  same idempotency key and the same body, an unreadable answer that is not
  sent again, an approved review that is not loaded again, a load on its way
  that the approval overtakes (held through `FixtureAPI`'s `hold`), each refused signature,
  403, 404, 409 and 422 on the challenge and on the approval, a face that does
  not match, a signer that cannot sign, and Approve off while offline.
  `SignInKeyRegistrarTests` checks the new sign-in, `CallFailureTests` which
  failures may have reached the server, and `ReviewUITests` approves through
  the stub, opens the next review and shows and closes a problem.
- Only a device has a Secure Enclave and a passcode. Approving with Face ID
  enrolled, removed and enrolled again is a manual check on a device.
