# Approve a review in the app

How the Stride mobile app approves a task waiting in Review with a signature
the server can verify ([design](../plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md),
§6.6, §7.5, decision 4). An approval is two requests:

1. `POST /api/me/reviews/:task_id/approval_challenge` returns a single-use
   nonce.
2. The app unlocks its approval key with Face ID, a fingerprint or the
   passcode, signs the [signing string](#the-signing-string), and sends
   `POST /api/me/reviews/:task_id/approve` with the nonce and the signature.

A biometric check made only in the app could be skipped by a modified app.
The signature proves that the device's protected key was unlocked for this
exact approval, and the server checks it against the approval public key the
device registered at sign-in. Phase 1 accepts no approval without one.

This is not an agent endpoint. Agents keep using the routes in the
[API reference](README.md) with their API token.

## Authentication

A device access token, sent as `Authorization: Bearer <token>`, exactly as for
[GET /api/me](get_me.md#authentication), with the same
[`X-Stride-App` header](get_me.md#the-version-header).

## The checks, in order

Both routes run these checks in this order and answer with the first that
fails. The challenge runs checks 1 to 4, so a phone learns that a change is too
large before it asks for a biometric, and then checks the
[`review_fingerprint`](#post-apimereviewstask_idapproval_challenge) it was
sent; the approval runs all five.

| # | Check | Refusal |
|---|---|---|
| 1 | The person can review the task: it exists, is not archived and is on a board they can **write** to | `404 {"error": "Not Found"}` |
| 2 | The review is still pending, and its `review_requested_at` matches the one sent | `409 already_decided` or `409 resubmitted`, with the review's current state |
| 3 | The plan: `mobile_app`, for the person and then the task's board | `403 plan_required` |
| 4 | The large-change guard, for the device's class | `422 too_large_for_phone` on a phone |
| 5 | The signature: a nonce and a signature are sent, the nonce was issued to this device for this review and is unused and unexpired, and the signature verifies against the device's approval public key | `422 signature_rejected` with a `reason` |

The access check runs first, so a `409` body, a `403` or a `422` only ever goes
to someone who may review the task. A task they cannot see, can only read, or
an id that is not one all answer the same `404`, as for
[GET /api/me/reviews/:task_id](me_reviews.md#who-can-see-a-review).

The approval itself runs in one transaction that locks the task and runs the
access, state and submission checks again, so a task archived or a person's
write access removed in the moment between the checks and the approval
answers `404`, and a device revoked while its request was in flight answers
`401`, rather than approving.

Once every check passes, Stride approves through the same function the web
Review Queue uses, so the task moves to Done and its dependents are unblocked
exactly as on the web. The `review_approved` audit event records `via` (`ios`
or `android`), the device, its class and `approval_key: true`.

## POST /api/me/reviews/:task_id/approval_challenge

The body is required. It carries `review_fingerprint`, the value
[GET /api/me/reviews/:task_id](me_reviews.md) returned for the review screen
the person is looking at, sent back unchanged. Stride issues a nonce only when
it matches the task's fingerprint now, so an edit made after the screen loaded
is never signed unseen:

- a body without `review_fingerprint`, or one that is not 64 lowercase
  hexadecimal characters, is `400 {"error": "Bad Request", "message": "..."}`;
- one that differs from the task's now is `409 edited`. Reload the review and
  ask again with its new `review_fingerprint`.

When the body also carries `review_requested_at` and the task's differs, the
answer is `409 resubmitted`.

```json
{
  "review_requested_at": "2026-11-18T09:30:00Z",
  "review_fingerprint": "3f9a1c0e6b2d4f8a7c5e9b1d3f7a2c4e6b8d0f2a4c6e8b0d2f4a6c8e0b2d4f6a"
}
```

`201 Created`:

```json
{
  "data": {
    "nonce": "sdan_EXAMPLE0nonce0value0only0for0documentation0",
    "expires_at": "2026-11-18T09:42:00Z",
    "task_id": 4812,
    "review_requested_at": "2026-11-18T09:30:00Z",
    "decision": "approve",
    "signing_version": "stride-approval-v1"
  }
}
```

- `nonce` is shown once. Stride stores only its SHA-256 hash.
- It is valid for 2 minutes (`expires_at`) and can be used once.
- It is bound to this device, this task, the task's `review_requested_at`,
  the `review_fingerprint` it was asked with, and the work submitted for
  review when it was issued. A nonce issued to
  another device, for another task, or before the task was sent for review
  again is refused as `invalid`, even when the resubmission fell in the same
  second and left `review_requested_at` unchanged.
- It is also bound to the task fields the review screen shows (the title,
  priority, time spent, and the task's own acceptance criteria and security
  considerations), to the task's description, and to the status of each
  section verdict the screen shows. An edit to any of them after the nonce
  was issued refuses the approval as `invalid`; request a new challenge to
  approve the task as it is now. That includes an edit to a field the screen
  does not show when it changes a verdict's status, such as clearing the
  task's patterns, testing strategy or pitfalls. An edit to any other field,
  such as the task's position, does not.
- `review_requested_at` is the value to sign: an ISO 8601 UTC timestamp, or
  the empty string for a task that has none. Send it back exactly as it was
  returned.

## POST /api/me/reviews/:task_id/approve

```json
{
  "review_requested_at": "2026-11-18T09:30:00Z",
  "nonce": "sdan_EXAMPLE0nonce0value0only0for0documentation0",
  "signature": "MEUCIQ...EXAMPLE"
}
```

- `review_requested_at` is required: the value the review screen and the
  challenge returned, sent back unchanged, or `null` or `""` for a task that
  has none. A body without it, or with a value that is not an ISO 8601
  extended-format timestamp such as `2026-11-18T09:30:00Z`, is
  `400 {"error": "Bad Request", "message": "..."}`. The challenge's optional
  `review_requested_at` takes the same values.
- `nonce` is the challenge's nonce.
- `signature` is the signature of the [signing string](#the-signing-string).

`200 OK`:

```json
{
  "data": {
    "task_id": 4812,
    "identifier": "W2701",
    "review_status": "approved",
    "reviewed_at": "2026-11-18T09:41:12Z"
  }
}
```

## Retrying safely

The approve route takes an optional `Idempotency-Key` header. A retry with the
same key from the same device for the same task within 24 hours is answered
with the first approval's `200` and body instead of `409 already_decided`, and
two requests with one key sent at the same time approve once. Only a
successful approval is stored, so a refused one's retry runs again. A retry
that arrives while the first approval is committing finds its nonce used by
that approval: it is answered with the replay when it carries the key, or
`409 already_decided` when it does not, never `422 reused`, and writes no
`approval_signature_rejected` event. The key is bound to the approval's
`review_requested_at` and a hash of its signature, so a retry resends the
same body: a resend with other signature bytes, such as a bad signature, or
with none, is a new request that runs its checks and is refused, never
answered with the stored `200`. The rules
are shared with the request for changes and are in
[Request changes on a review in the app](me_review_request_changes.md#retrying-safely-idempotency-key).

## The signing string

The app signs these five lines joined by a line feed (`\n`, 0x0A), in UTF-8,
with no trailing line feed:

```text
stride-approval-v1
<nonce>
<task id, in decimal>
<review_requested_at>
approve
```

For the challenge above that is:

```text
stride-approval-v1
sdan_EXAMPLE0nonce0value0only0for0documentation0
4812
2026-11-18T09:30:00Z
approve
```

- `<review_requested_at>` is the challenge's `review_requested_at` exactly as
  it was returned, or the empty string (an empty fourth line) when it is
  empty.
- The last line, `approve`, is the decision, so a signature can never be
  replayed as another kind of decision.
- The signature is ECDSA on the P-256 curve with SHA-256 over those bytes, as
  a DER `ECDSA-Sig-Value`, in unpadded URL-safe base64. On iOS that is
  `SecKeyCreateSignature` with `.ecdsaSignatureMessageX962SHA256`, or
  CryptoKit's `derRepresentation`; on Android, `SHA256withECDSA`. A raw
  `r || s` signature is refused as `invalid`, and so is padded base64 or a
  last character with stray low bits: only the canonical unpadded encoding
  verifies, for the signature and for the key.
- The key is the approval key the device registered at sign-in: the
  uncompressed P-256 public point in unpadded URL-safe base64.

## Errors

- `400 {"error": "Bad Request", "message": "..."}` for an approval without a
  valid `review_requested_at`, or with an unacceptable `Idempotency-Key`.
- `401 {"error": "Invalid access token"}` for a missing, expired or revoked
  device token, including a device revoked while its approval was in flight.
- `403` with the `plan_required` body of
  [GET /api/me/reviews/:task_id](me_reviews.md#plans).
- `404 {"error": "Not Found"}` as in [the checks](#the-checks-in-order).
- `409` when the review was decided or sent for review again since the app
  loaded it, or (from the challenge only) when the task was edited since.
  `error` is `already_decided`, `resubmitted` or `edited`, and `review` is
  the current state, so the app can say who decided it and when:

  ```json
  {
    "error": "already_decided",
    "message": "This review has already been decided.",
    "review": {
      "task_id": 4812,
      "identifier": "W2701",
      "review_status": "approved",
      "review_requested_at": "2026-11-18T09:30:00Z",
      "reviewed_at": "2026-11-18T09:39:02Z",
      "reviewed_by": "Sam Rivera"
    }
  }
  ```

- `422 too_large_for_phone` when a phone tries to approve a large change. Its
  `size` is counted as `GET /api/me/reviews/:task_id` counts it, and `limits`
  are the phone limits. A tablet, and the web, may approve it:

  ```json
  {
    "error": "too_large_for_phone",
    "message": "This change is too large to approve on a phone. Approve it on a tablet or on the web.",
    "size": { "files": 14, "files_unknown": false, "changed_lines": 652, "truncated": false },
    "limits": { "max_files": 10, "max_changed_lines": 500 }
  }
  ```

- `422 signature_rejected` when the signature check refuses the approval.
  `reason` is `missing` (no nonce or no signature), `invalid` (the nonce was
  not issued to this device for this review, the task fields the review
  screen shows, the description or a section verdict's status changed since,
  or the signature does not verify),
  `expired` or `reused`; request a new challenge for any of them.
  Each refusal writes an `approval_signature_rejected` audit event with the
  reason, never the nonce or the signature:

  ```json
  {
    "error": "signature_rejected",
    "reason": "expired",
    "message": "The approval nonce has expired. Request a new one."
  }
  ```

- `422 {"error": "approval_failed", "reason": "..."}` when the approval itself
  cannot be made. `reason` is `column_not_found` when the board has no Done
  column (no column named Done, ignoring case and surrounding whitespace), or
  `invalid_column`, `review_not_performed` or `invalid_review_status`.
- `429 {"error": "rate_limited", "message": "..."}`, with a `retry-after`
  header in seconds, when this device has sent more than 20 challenge,
  approve and [request changes](me_review_request_changes.md) requests,
  together, in a minute. Each approval takes two, so a device can approve ten
  reviews a minute. The limit is per device: another
  device of the same person is not affected.

## Telemetry and retention

A phone refused by the guard emits `[:kanban, :review, :phone_approval_refused]`,
and a refused signature emits `[:kanban, :review, :approval_signature_rejected]`
([telemetry](../telemetry.md#app-approval-events)). Expired challenges, used or
not, are deleted daily at 03:53 UTC. Stored `Idempotency-Key` results expire
after 24 hours and are deleted hourly.
