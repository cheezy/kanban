# Request changes on a review in the app

How the Stride mobile app sends a task waiting in Review back to its agent
with feedback, and how the app retries a review decision safely when a
response is lost ([design](../plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md),
§7.5, §8). Requesting changes is one request,
`POST /api/me/reviews/:task_id/request_changes`. It needs no signature: the
task stays in Review, so nothing is approved.

This is not an agent endpoint. Agents keep using the routes in the
[API reference](README.md) with their API token.

## Authentication

A device access token, sent as `Authorization: Bearer <token>`, exactly as for
[GET /api/me](get_me.md#authentication), with the same
[`X-Stride-App` header](get_me.md#the-version-header).

## POST /api/me/reviews/:task_id/request_changes

```json
{
  "review_requested_at": "2026-11-18T09:30:00Z",
  "notes": "Handle the empty member list before showing the table."
}
```

- `review_requested_at` is required, with the same values as on
  [the approve route](me_review_approval.md#post-apimereviewstask_idapprove):
  the value the review screen returned, sent back unchanged, or `null` or `""`
  for a task that has none.
- `notes` is required and must have something visible in it: it is the
  feedback the agent picks up. Notes made only of whitespace, invisible
  characters such as a zero-width space, or combining marks count as blank. It is stored on the task and never echoed back or written to the
  audit event.

`200 OK`:

```json
{
  "data": {
    "task_id": 4812,
    "identifier": "W2701",
    "review_status": "changes_requested",
    "reviewed_at": "2026-11-18T09:41:12Z"
  }
}
```

## The checks, in order

The route runs checks 1 to 3 of
[the approval](me_review_approval.md#the-checks-in-order), in the same order,
and answers with the first that fails:

| # | Check | Refusal |
|---|---|---|
| 1 | The person can review the task: it exists, is not archived and is on a board they can **write** to | `404 {"error": "Not Found"}` |
| 2 | The review is still pending, and its `review_requested_at` matches the one sent | `409 already_decided` or `409 resubmitted`, with the review's current state |
| 3 | The plan: `mobile_app`, for the person and then the task's board | `403 plan_required` |

Missing or blank notes are checked only after these, so a `422` only ever
goes to someone who may review the task. There is **no large-change guard**:
a phone may ask for changes on a change of any size, as
[GET /api/me/reviews/:task_id](me_reviews.md) promises.

The request runs in one transaction that locks the task and runs the access
and state checks again, so a task archived, or a person's write access removed,
in the moment between the checks and the request answers `404`, a review
decided or resubmitted since answers `409`, and a device revoked while its
request was in flight answers `401`.

Once every check passes, Stride requests changes through the same function the
web Review Queue uses: `review_status` becomes `changes_requested`, the notes
are stored and the task stays in Review for the agent. The
`review_changes_requested` audit event records `via` (`ios` or `android`), the
device and its class.

## Retrying safely: Idempotency-Key

Both review decisions, this route and
[`POST /api/me/reviews/:task_id/approve`](me_review_approval.md#retrying-safely),
take an optional `Idempotency-Key` header. A phone on a train can send a
decision and lose the answer; without a key its retry would find the review
already decided and answer `409`.

```http
Idempotency-Key: 4f8e2a6c-1b3d-4e5f-8a7b-9c0d1e2f3a4b
```

- Pick a new key, such as a UUID, for each decision, and send the same key
  again, unchanged, when retrying that request.
- A retry with the same key from the same device, for the same decision on the
  same task, within **24 hours** is answered with the first request's status
  and body. The decision is not made again, so a retried approval returns its
  first `200` rather than `409 already_decided`.
- The key is bound to the request it was sent with: the `review_requested_at`
  and a SHA-256 hash of the `signature` of an approval, and the
  `review_requested_at` and `notes` of a request for changes. The same key
  sent with others is a new request: on a review already decided it answers
  `409 already_decided`, never the first `200` with the new notes dropped.
  So a retried approval resends the same body, with the same nonce and
  signature. An approval resent with other signature bytes, such as a new
  challenge's, a bad signature or the high-s twin of the first, or with no
  signature, is a new request too: it runs its checks and is refused, never
  answered with the stored `200` unchecked.
- Before a stored result is replayed, the person's access to the task and the
  `mobile_app` plan are checked again, so a person removed from the board, a
  task archived since, or a plan that no longer includes the app answers
  `404` or `403` rather than the stored `200`.
- Two requests with one key sent at the same time make the decision once, and
  both answer `200` with the same body.
- Only a successful result is stored. A refused request, such as a `409`,
  `422`, `400` or `401`, stores nothing, so its retry runs again.
- A key sent for another task, or for the other decision, acts anew and never
  returns another task's result. The same key from another device is a
  different key.
- After 24 hours the key acts anew. The window is at least 24 hours: it is
  rounded up to the next whole second.
- Without the header a request runs as it always did.
- The key is 1 to 255 visible ASCII characters. An empty, longer or otherwise
  malformed key, or the header sent twice, is
  `400 {"error": "Bad Request", "message": "Idempotency-Key must be sent at most once, as 1 to 255 visible ASCII characters, such as a UUID."}`.
- A replayed retry still counts against the device's rate limit.

Stride stores only a SHA-256 hash of the key, together with the decision and
the task, in the `device_nonces` table, and never logs the key. An hourly job
deletes expired keys.

## Errors

- `400 {"error": "Bad Request", "message": "..."}` for a body without a valid
  `review_requested_at`, or an unacceptable `Idempotency-Key`.
- `401 {"error": "Invalid access token"}` for a missing, expired or revoked
  device token, including a device revoked while its request was in flight.
- `403` with the `plan_required` body of
  [GET /api/me/reviews/:task_id](me_reviews.md#plans).
- `404 {"error": "Not Found"}` as in [the checks](#the-checks-in-order).
- `409 already_decided` or `409 resubmitted`, with the review's current
  state, as on [the approve route](me_review_approval.md#errors).
- `422 {"errors": {"notes": ["can't be blank"]}}` when `notes` is missing,
  blank or not a string, and
  `422 {"errors": {"notes": ["contains characters that are not allowed"]}}`
  when it holds a NUL byte.
- `429 {"error": "rate_limited", "message": "..."}`, with a `retry-after`
  header in seconds, when this device has sent more than 20 challenge,
  approve and request changes requests, together, in a minute.
