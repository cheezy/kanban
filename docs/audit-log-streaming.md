# Audit Log Streaming

An Organization can send its audit log, as it happens, to a security tool:
Splunk, Datadog, or any HTTPS endpoint. This guide is for the org-admins who
set destinations up, for the people who run the receiving end, and for the
operators who run a Stride instance.

Only an enabled org-admin of the Organization can see or change its
destinations. They are at `/org/audit/streaming`, reached with **Audit
streaming** on the Organization console or **Streaming** on the Organization
audit log page. A new destination is added at `/org/audit/streaming/new`; each
destination has its own page at `/org/audit/streaming/<id>` and its edit form
at `/org/audit/streaming/<id>/edit`. Stride's site admins cannot see an
Organization's destinations.

[Organizations and Workspaces](organizations.md#the-organization-audit-log)
describes the audit log itself, and
[Signed Audit Log Exports](audit-log-signed-exports.md) covers verifying an
exported file.

## What streaming sends and when

- **Every audit event of the Organization**, in the order the events were
  committed, except the actions a destination leaves out (see
  [Leaving out actions](#leaving-out-actions)). Site events, which belong to
  no Organization, are never sent.
- **Within about a minute.** A sweep runs every minute and starts the
  delivery of newly waiting events; there is no faster path for a new event.
  A retry, and the next batch of a catch-up, are queued by the delivery run
  itself, at their own time.
- **In batches** of at most 500 events and 900,000 bytes, the size of the
  request body before compression, counted as each type of destination
  writes it: Datadog's entry around every event, with its tags, service and
  message; Splunk's HEC fields; the HTTPS JSON envelope or NDJSON newlines.
  So a Datadog destination with many long tags sends fewer events per batch.
  A single event larger than that is sent on its own. A retry rebuilds the
  body under the destination's current settings without measuring it again,
  so after a tags, service or format change a retried batch can be larger
  than it was cut, and a 413 then halves it. Every request body is
  compressed with gzip. The bytes a delivery attempt records stay the size
  of the events alone, as JSON with one separator each, without the entry or
  envelope around them, so they do not follow a change to the tags, service
  or format.
- **At least once.** A batch can arrive more than once, and an event can
  arrive in more than one batch. Every receiver drops duplicates by the event
  `id` with its `instance` (see [Changing the filters re-sends the waiting batch](#changing-the-filters-re-sends-the-waiting-batch)).
- **From the starting point you choose.** **Send events from** offers **Now:
  only new events**, **The last 24 hours**, **The last 7 days** or
  **Everything in the audit log** for Splunk and HTTPS, and **Now: only new
  events** or **The last 17 hours** for Datadog. A destination catching up
  on old events sends at most one batch every 2 seconds while its next
  waiting event is more than 10 minutes old.

Saving the form sends a test event to the destination. **Send test event**
on the destination's row in the list sends another one. See
[Test events](#test-events).

## Setting up a destination

Choose **Add destination**, then the **Type**. Each type asks for a name, a
connection, where to start from (**Send events from**) and what is sent. A
saved URL, token, API key or header value is never shown again: the list and
the destination page show the host and, for a value of 16 characters or more,
its last 4 characters, and the edit form keeps a saved value when its field
is left blank.

On a production instance every destination is reached over HTTPS, and a
Splunk HEC URL must start with `https://` on any instance. The certificate
must verify: there is no setting that skips the check. Redirects are never
followed.

### Splunk HTTP Event Collector

| Field | What to enter |
|---|---|
| **HEC URL** | The collector address, ending in `/services/collector` or `/services/collector/event`, with no query string and no `#` part. Any other path is refused, `/services/collector/raw` included, because Splunk would index each line as raw text |
| **HEC token** | The HTTP Event Collector token. Stride sends it as `Authorization: Splunk <token>` |
| **Index (optional)** | At most 80 lowercase letters, digits, `_` and `-`, not starting with `-`. Left blank, the token's default index is used |
| **Source type** | At most 100 characters. Defaults to `stride:audit` |

- **Find the collector address, not the web address.** Splunk Cloud's
  collector host has one of three forms: `http-inputs-<stack>.splunkcloud.com`
  on AWS, `http-inputs.<stack>.splunkcloud.com` on Google Cloud and Azure,
  and `http-inputs.<stack>.splunkcloudgc.com` for FedRAMP. A
  `splunkcloud.com` or `splunkcloudgc.com` host that does not start with
  `http-inputs` gets the warning "This looks like the Splunk Cloud web
  address. The collector address starts with http-inputs." Self-managed
  Splunk usually listens for HEC on port `8088`, so its URL looks like
  `https://splunk.example.internal:8088/services/collector/event`; it must
  still be reachable from the internet and serve a certificate that verifies.
- **Turn indexer acknowledgement off on the token.** Stride does not use it
  and never sends `X-Splunk-Request-Channel`. A token with acknowledgement on
  makes every batch fail with "Turn off indexer acknowledgement on this HEC
  token".
- **Splunk Cloud trial stacks are not supported.** Their collectors use
  self-signed certificates, and Stride never skips certificate verification.
- Each event is sent as a HEC event with `time` (the event's time in epoch
  seconds with milliseconds), `host` (the Stride instance), `source` `stride`,
  your source type, your index when set, and the [payload](#the-payload) as
  `event`.

Splunk answers that are a setting problem, such as an index the token can't
write to or acknowledgement turned on, make the destination **Failing** at
once with the fix in words, and are never skipped: every batch would fail
the same way.

### Datadog

| Field | What to enter |
|---|---|
| **Site** | One of `datadoghq.com`, `us3.datadoghq.com`, `us5.datadoghq.com`, `datadoghq.eu`, `ap1.datadoghq.com`, `ap2.datadoghq.com`, `uk1.datadoghq.com`, `ddog-gov.com` and `us2.ddog-gov.com`. Stride sends to `https://http-intake.logs.<site>/api/v2/logs`, so there is no URL to enter |
| **API key** | A Datadog API key. Stride sends it as `DD-API-KEY` |
| **Service** | At most 100 characters. Defaults to `stride-audit` |
| **Tags (optional)** | Up to 90 `key:value` tags, separated by spaces, commas or new lines, each at most 200 characters. A key starts with a letter, and a value can't be empty. `source` and `organization_id` are taken by Stride |

- Each log entry has `ddsource` `stride`, your service, `hostname` (the
  Stride instance), `ddtags` starting with `source:stride,organization_id:<id>`,
  `date` (the event's time in epoch milliseconds), a short English `message`
  such as "Organization member removed by alex@northwind.example", and the
  [payload](#the-payload) under `stride`.
- **The 17-hour limit.** Datadog drops log entries more than 18 hours old and
  still answers that it accepted them. So Stride never sends Datadog an event
  older than 17 hours: a Datadog destination starts from now or from the
  last 17 hours, and an event that is already older than 17 hours when it
  would be sent is skipped and recorded as a [gap](#gaps) with the reason
  "Too old for Datadog". A Datadog destination that is failing for more than
  17 hours therefore loses events.

### Your own HTTPS endpoint

| Field | What to enter |
|---|---|
| **URL** | The `https://` address that receives the batches. It is stored as a secret, because some tools put their token in the URL |
| **Format** | **JSON batch** (the default) or **NDJSON** |
| **Authorization header name (optional)** | A header your endpoint needs, such as `Authorization` or `X-goog-api-key` |
| **Authorization header value** | Its value, such as `Bearer YOUR_TOKEN`. The name and the value are given together |

A **JSON batch** is one JSON object per request, with the content type
`application/json`:

```json
{"version": 1, "batch_id": "<uuid>", "destination_id": 31, "organization": {"id": 210, "name": "Northwind Studio"}, "events": [{"id": "9001", "schema": "stride.audit.v1"}]}
```

**NDJSON** is one event per line, each line ending in a newline, with the
content type `application/x-ndjson`. Sumo Logic and Google Security
Operations prefer it.

Stride sets these headers itself, so they can't be used as the authorization
header, in any case: `Content-Type`, `Content-Encoding`, `Content-Length`,
`Host`, `User-Agent`, `X-Stride-Signature`, `X-Stride-Audit-Signature`,
`X-Stride-Batch`, `X-Stride-Event-Count` and `X-Stride-Destination`. Nor can
the names that change how a request is sent: `Connection`, `Keep-Alive`,
`Proxy-Connection`, `TE`, `Trailer`, `Transfer-Encoding`, `Upgrade` and
`Expect`.

Stride creates a **signing secret** for the destination and shows it once,
when the destination is created: "Copy it now — you won't be able to see it
again." Your receiver uses it to check the HMAC signature (see
[Verifying an HTTPS delivery](#verifying-an-https-delivery)). **Rotate
signing secret** on the destination page makes a new one and shows it once.
After a rotation the old secret keeps working for 24 hours, and the secret
can't be rotated again until then.

### Collectors that only accept listed addresses

Stride sends from addresses that can change, and does not publish a list of
them. A collector that only accepts connections from listed addresses, such
as a Splunk Cloud stack whose HEC allow list has been narrowed, refuses
Stride's connections, and the destination shows "Could not connect to the
destination". **Such collectors are not supported.** Datadog's intake is not
subject to an account's IP allow list.

## The payload

Every type carries the same event object, schema `stride.audit.v1`. Splunk
puts it in `event`, Datadog in `stride`, and an HTTPS endpoint receives it as
it is:

```json
{
  "id": "9001",
  "schema": "stride.audit.v1",
  "occurred_at": "2026-11-11T09:42:46.015000Z",
  "action": "org_member_removed",
  "action_label": "Organization member removed",
  "metadata": {"user_id": 77, "organization_id": 210, "member_user_id": 512},
  "organization": {"id": 210, "name": "Northwind Studio"},
  "actor": {"user_id": 77, "email": "alex@northwind.example", "in_organization": true},
  "ip": "203.0.113.24",
  "instance": "stride.example.com"
}
```

- **`id`** is the audit event's id, as a string so that tools using
  JavaScript numbers keep every digit. With `instance`, it identifies the
  event: use it to drop duplicates. A [test event](#test-events) always has
  the id `0`, which no real event has.
- **`instance`** is the Stride instance's host name. Like `actor`, it is read
  again on every attempt, not kept with the batch, so it changes between two
  attempts of one batch only if the operator changes the instance's host in
  between. A retry then carries the new host, and a receiver that drops
  duplicates by `instance` and `id` stores those events a second time. Change
  the host only when every destination is up to date, or drop duplicates by
  `id` alone while the change settles.
- **`occurred_at`** is when the event was recorded, in UTC.
- **`action_label`** is always in English, whatever language the
  org-admins use.
- **`organization`** carries the Organization's id and name. Every retry of a
  batch carries the name it had when the batch was made.
- **`actor`** is read again on every attempt, unlike `organization`. A retry
  carries the actor's email as it is at that attempt, `null` once the account
  has been deleted. A deleted actor's `user_id` is still sent when the event's
  own record kept it, and is `null` when it did not; the event's `ip` and
  `metadata` are sent as the two items below describe. An event from before
  Stride recorded whether its actor was a member, whose actor has since left
  the Organization, goes out as an outside actor. This is deliberate: a retry
  never re-sends an email Stride has since deleted, or an actor it would now
  hide.
- **An actor from outside the Organization**, such as a Stride site admin, is
  sent as on the Organization audit page: `user_id`, `email` and `ip` are
  `null`, `in_organization` is `false`, and the user id, email and IP address
  keys are removed from `metadata`.
- **Include email and IP addresses** is on by default. When an org-admin
  turns it off, each event is sent with `ip` and `actor.email` set to `null`
  and without any `email` or `ip` key in `metadata`, at any depth. The user
  id is still sent.

### Leaving out actions

**Leave out these actions** stops a destination from receiving the chosen
actions. Changes to audit streaming itself, every action whose name starts
with `audit_stream_`, are always sent and can't be left out, so a tool
always sees a destination being changed, paused, skipped or deleted.

### Changing the filters re-sends the waiting batch

A change to **Leave out these actions** or to **Include email and IP
addresses** applies to events already waiting, not only to new ones. If a
batch is waiting to be sent, or retried, when the change is saved, that
batch is dropped and its events are sent again under the new settings, in a
batch with a **new `batch_id`**. The form says so: "The waiting batch will be
sent again under the new settings." A send already under way finishes as it
started.

A new `batch_id` also comes from a batch that the destination refused as too
large (HTTP `413`), which Stride halves and sends again, and from a waiting
batch that retention shortened.

Any other change, such as the HTTPS endpoint's **Format** or Datadog's
**Service** or **Tags**, does not drop the waiting batch. Its next attempt
sends the same events, under the same `batch_id`, in the new settings. The
`batch_id` stays the same on purpose: an HTTPS endpoint that stored an
attempt Stride never saw answered can tell that the retry is that batch. The
signed copy is the `batch_id` in a JSON batch's body. The `x-stride-batch`
header, the only copy in an NDJSON batch, is covered by no signature, so use
it only to correlate attempts, never to accept, skip or drop events. Splunk
and Datadog requests carry no `batch_id` at all, and every receiver drops
duplicates by the event's `id` with its `instance`.

So a receiver must drop duplicates by the event's `id` (with its
`instance`), whatever the destination type, never by `batch_id` (which only
HTTPS requests carry), the body's hash or the signature. The same
`batch_id` always names the same events, but two different `batch_id`
values can hold the same event, so dropping a batch by its id never replaces
dropping events by theirs. Only the events and the `batch_id` stay the same
from one attempt to the next. The request can change: the body with the
actor fields, the format, Splunk's index and source type, or Datadog's tags
and service, and the headers with the signatures. A different request under
the same `batch_id` is not a sign of a tampered retry.

## Verifying an HTTPS delivery

Splunk and Datadog check their own tokens, and Stride does not sign batches
sent to them. A batch sent to an HTTPS endpoint carries these headers, in
lowercase on the wire:

| Header | Value |
|---|---|
| `x-stride-destination` | The destination's id |
| `x-stride-batch` | The batch id, the same on every retry of the batch |
| `x-stride-event-count` | How many events the batch holds |
| `x-stride-signature` | `t=<unix seconds>,v1=<hex HMAC-SHA256>`, with a second `v1` during a rotation |
| `x-stride-audit-signature` | `t=<unix seconds>,kid=<key id>,ed25519=<signature>`. Left out when the Stride instance has no signing key |
| `user-agent` | `Stride-AuditStream/1` |
| `content-encoding` | `gzip` |

There is no Organization or timestamp header: the Organization is in the
body, and the time is the `t` inside both signatures. Each retry is signed
again with a new `t`.

The two signatures prove different things, and a receiver can check either
or both:

- **The HMAC** proves the batch came from someone who holds this
  destination's signing secret.
- **The Ed25519 signature** proves the batch came from this Stride instance,
  with no shared secret: the receiver checks it against the public key the
  instance publishes. It can be kept with the events as evidence of where
  they came from.

The examples below are a [Python](#python) and a [Node.js](#nodejs) receiver.
Each is a set of functions to call from your request handler with the
request's headers, as a map of lowercase names, and its raw body bytes.

### Inflate the body first

Both signatures are over the **decompressed** body, the JSON or NDJSON text
before gzip. Inflate the raw body, then verify the inflated bytes, and parse
the JSON only afterwards: parsing and encoding it again can change the bytes.
Many frameworks and proxies inflate a gzip body before your code sees it.
Check whether yours does, and if it does, verify the bytes it hands you and
do not inflate them twice.

Stride's batches inflate to about 900 KB at most, unless a single event is
larger. Cap how far you inflate, so a small request can't fill your memory.

### Checking the HMAC signature

The HMAC uses the webhook signature format, so a receiver that already
checks Stride webhooks can reuse its code on the inflated bytes; see
[Verify the signature](webhooks.md#verify-the-signature). To check it:

1. Split `x-stride-signature` on `,`, and split each part on its **first**
   `=` only. Take the one `t=` value and every `v1=` value.
2. Refuse the request if `t` is more than five minutes from your clock, so an
   old delivery can't be replayed.
3. Compute the HMAC-SHA256 of `"<t>.<inflated body>"`, keyed with the
   destination's signing secret, as lowercase hex.
4. Accept the request if it equals **any** `v1` value, using a constant-time
   comparison.

During the 24 hours after a rotation the header carries two `v1` values,
the old secret's first: `t=<t>,v1=<old>,v1=<new>`. A receiver holding either
secret verifies, so update the receiver to the new secret within those 24
hours.

### Checking the Ed25519 signature

1. Split `x-stride-audit-signature` the same way. It must have exactly one
   `t`, one `kid` and one `ed25519` value.
2. Refuse the request if `t` is more than five minutes from your clock. Skip
   only this step when you check a stored batch later, as evidence.
3. Choose the public key whose `kid` matches from the instance's key set at
   `https://<your Stride host>/.well-known/stride-audit-signing-keys`, and
   refuse a `kid` listed under `revoked`. The key set may be cached for up to
   an hour, so when a `kid` is not in your copy, fetch the key set again once
   before refusing it: an operator may have just rotated the key.
4. Decode the signature and the key's `x` from **base64url without padding**:
   neither carries `=` padding, so add it back before decoding with a decoder
   that expects it. The signature is 64 bytes and the key 32.
5. Verify the signature over `"<t>.<destination id>.<inflated body>"`, where
   `<destination id>` is the id **you** expect, written in decimal.

[The key endpoint](audit-log-signed-exports.md#the-key-endpoint) describes
the key set and how to fetch one key as PEM, and
[Key id and fingerprint](audit-log-signed-exports.md#key-id-and-fingerprint)
how to check a key against the fingerprint your org-admins recorded. To
check a signature from the command line, use OpenSSL 3 as in
[Verifying with OpenSSL 3](audit-log-signed-exports.md#verifying-with-openssl-3):
the `openssl` that macOS ships is LibreSSL, which can't do it.

### Checks beyond the signature

The Ed25519 key is the instance's, not the destination's, so a valid
signature alone proves only that this Stride instance sent the batch. A
receiver also:

- refuses a `t` more than five minutes from its clock (both signatures);
- checks that `x-stride-destination`, and the `destination_id` of a JSON
  batch, is its own destination's id;
- checks that every event's `organization.id`, and the `organization.id` of
  a JSON batch, is its own Organization's id;
- drops events it has already received, by `instance` and `id`. It never
  drops a batch by its `x-stride-batch` header: no signature covers that
  header, so a replayed batch with a rewritten header could otherwise make a
  later genuine batch be dropped.
- reads the body by the format the destination was set up with, never by
  the `content-type` header, which no signature covers either.

To keep a batch as evidence, store the inflated body and the
`x-stride-audit-signature` header unchanged.

### Python

The HMAC check needs only the standard library. The Ed25519 check uses the
`cryptography` package, which `pip install cryptography` installs.
`YOUR_SIGNING_SECRET` stands for the secret Stride showed you; load it from
your own secret store, never from source code.

```python
import base64
import hashlib
import hmac
import json
import re
import time
import zlib

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

MAX_INFLATED = 16 * 1024 * 1024


def inflate(raw_body: bytes) -> bytes:
    decompressor = zlib.decompressobj(wbits=31)  # 31: gzip framing
    body = decompressor.decompress(raw_body, MAX_INFLATED)
    if decompressor.unconsumed_tail or decompressor.unused_data or not decompressor.eof:
        raise ValueError("not one complete gzip member, or larger than MAX_INFLATED")
    return body


def header_values(header, name):
    if not isinstance(header, str):
        return []
    parts = [part.split("=", 1) for part in header.split(",") if "=" in part]
    return [value for key, value in parts if key == name]


def fresh(timestamps, tolerance):
    if len(timestamps) != 1 or not re.fullmatch(r"[0-9]+", timestamps[0]):
        return False
    return tolerance is None or abs(time.time() - int(timestamps[0])) <= tolerance


def verify_hmac(header, body: bytes, secret: str, tolerance=300) -> bool:
    timestamps = header_values(header, "t")
    signatures = header_values(header, "v1")
    if not signatures or not fresh(timestamps, tolerance):
        return False
    expected = hmac.new(
        secret.encode(), timestamps[0].encode() + b"." + body, hashlib.sha256
    ).hexdigest()
    return any(
        hmac.compare_digest(expected.encode(), signature.encode())
        for signature in signatures
    )


def b64url_decode(value: str) -> bytes:
    if not re.fullmatch(r"[A-Za-z0-9_-]*", value):
        raise ValueError("not unpadded base64url")
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def verify_ed25519(header, body: bytes, destination_id: int, key_set: dict, tolerance=300) -> bool:
    timestamps = header_values(header, "t")
    kids = header_values(header, "kid")
    signatures = header_values(header, "ed25519")
    if len(kids) != 1 or len(signatures) != 1 or not fresh(timestamps, tolerance):
        return False
    message = timestamps[0].encode() + b"." + str(destination_id).encode() + b"." + body
    try:
        if any(entry.get("kid") == kids[0] for entry in key_set.get("revoked", [])):
            return False
        keys = [
            key
            for key in key_set.get("keys", [])
            if key.get("kid") == kids[0] and key.get("kty") == "OKP" and key.get("crv") == "Ed25519"
        ]
        if len(keys) != 1:
            return False
        public_key = Ed25519PublicKey.from_public_bytes(b64url_decode(keys[0]["x"]))
        public_key.verify(b64url_decode(signatures[0]), message)
    except (AttributeError, KeyError, TypeError, ValueError, InvalidSignature):
        return False
    return True


def organization_id_of(value):
    organization = value.get("organization") if isinstance(value, dict) else None
    return organization.get("id") if isinstance(organization, dict) else None


def is_event_of(event, organization_id) -> bool:
    return (
        isinstance(event, dict)
        and isinstance(event.get("id"), str)
        and isinstance(event.get("instance"), str)
        and organization_id_of(event) == organization_id
    )


def accept(headers, raw_body, secret, destination_id, organization_id, body_format, key_set, seen):
    """Returns the events not seen before, or None when the batch is refused.

    headers: lowercase names. body_format: "json" or "ndjson", as the
    destination was set up. key_set: the parsed key set, or None to skip the
    Ed25519 check. seen: a set of (instance, id) pairs already stored; keep it
    in a durable store.
    """
    try:
        if headers.get("x-stride-destination") != str(destination_id):
            return None
        body = inflate(raw_body)
        if not verify_hmac(headers.get("x-stride-signature"), body, secret):
            return None
        if key_set is not None and not verify_ed25519(
            headers.get("x-stride-audit-signature"), body, destination_id, key_set
        ):
            return None
        if body_format == "json":
            batch = json.loads(body)
            if not isinstance(batch, dict) or batch.get("destination_id") != destination_id:
                return None
            if organization_id_of(batch) != organization_id:
                return None
            events = batch.get("events")
        else:
            events = [json.loads(line) for line in body.splitlines() if line.strip()]
    except (ValueError, zlib.error):
        return None
    if not isinstance(events, list) or not all(is_event_of(e, organization_id) for e in events):
        return None
    new_events = [event for event in events if (event["instance"], event["id"]) not in seen]
    seen.update((event["instance"], event["id"]) for event in new_events)
    return new_events
```

Call `accept(headers, raw_body, "YOUR_SIGNING_SECRET", 31, 210, "json",
key_set, seen)` with your own destination and Organization ids and the
destination's format, and answer `2xx` once the events it returns are
stored. Answer `2xx` for `[]` too: every event in it was already stored.

`accept` returns `None` for every refusal, a body that is not gzip, is cut
short or inflates too far included, and changes nothing in `seen` when it
does. When it refuses because the key set you hold has no key with the
batch's `kid`, fetch the key set again and call it once more. Answer a
refused batch with `401`: Stride then shows "Credentials refused" and keeps
trying, where a `400` makes it stop on the batch after three tries (see
[When deliveries fail](#when-deliveries-fail)).

### Node.js

The same checks with Node's own `crypto` and `zlib` modules, on Node 16 or
later. `rawBody` is a `Buffer` of the request body as received.

```javascript
const crypto = require("crypto");
const zlib = require("zlib");

const MAX_INFLATED = 16 * 1024 * 1024;

function inflate(rawBody) {
  return zlib.gunzipSync(rawBody, { maxOutputLength: MAX_INFLATED });
}

function headerValues(header, name) {
  if (typeof header !== "string") return [];
  return header
    .split(",")
    .filter((part) => part.includes("="))
    .map((part) => [part.slice(0, part.indexOf("=")), part.slice(part.indexOf("=") + 1)])
    .filter(([key]) => key === name)
    .map(([, value]) => value);
}

function fresh(timestamps, tolerance) {
  if (timestamps.length !== 1 || !/^[0-9]+$/.test(timestamps[0])) return false;
  return tolerance === null || Math.abs(Date.now() / 1000 - Number(timestamps[0])) <= tolerance;
}

function verifyHmac(header, body, secret, tolerance = 300) {
  const timestamps = headerValues(header, "t");
  const signatures = headerValues(header, "v1");
  if (signatures.length === 0 || !fresh(timestamps, tolerance)) return false;
  const expected = Buffer.from(
    crypto.createHmac("sha256", secret).update(`${timestamps[0]}.`).update(body).digest("hex")
  );
  return signatures.some((signature) => {
    const given = Buffer.from(signature);
    return given.length === expected.length && crypto.timingSafeEqual(given, expected);
  });
}

function b64urlDecode(value) {
  if (!/^[A-Za-z0-9_-]*$/.test(value)) throw new Error("not unpadded base64url");
  return Buffer.from(value, "base64url");
}

function verifyEd25519(header, body, destinationId, keySet, tolerance = 300) {
  const timestamps = headerValues(header, "t");
  const kids = headerValues(header, "kid");
  const signatures = headerValues(header, "ed25519");
  if (kids.length !== 1 || signatures.length !== 1 || !fresh(timestamps, tolerance)) return false;
  const message = Buffer.concat([Buffer.from(`${timestamps[0]}.${destinationId}.`), body]);
  try {
    if ((keySet.revoked || []).some((entry) => entry.kid === kids[0])) return false;
    const keys = (keySet.keys || []).filter(
      (key) => key.kid === kids[0] && key.kty === "OKP" && key.crv === "Ed25519"
    );
    if (keys.length !== 1) return false;
    const signature = b64urlDecode(signatures[0]);
    if (signature.length !== 64) return false;
    const publicKey = crypto.createPublicKey({
      key: { kty: "OKP", crv: "Ed25519", x: keys[0].x },
      format: "jwk",
    });
    return crypto.verify(null, message, publicKey, signature);
  } catch (error) {
    return false;
  }
}

function organizationIdOf(value) {
  const organization = value !== null && typeof value === "object" ? value.organization : null;
  return organization !== null && typeof organization === "object" ? organization.id : undefined;
}

function isEventOf(event, organizationId) {
  return (
    event !== null &&
    typeof event === "object" &&
    typeof event.id === "string" &&
    typeof event.instance === "string" &&
    organizationIdOf(event) === organizationId
  );
}

// Returns the events not seen before, or null when the batch is refused.
// headers: lowercase names. bodyFormat: "json" or "ndjson", as the destination
// was set up. keySet: the parsed key set, or null to skip the Ed25519 check.
// seen: a Set of "instance/id" keys already stored; keep it in a durable store.
function accept(headers, rawBody, secret, destinationId, organizationId, bodyFormat, keySet, seen) {
  let events;
  try {
    if (headers["x-stride-destination"] !== String(destinationId)) return null;
    const body = inflate(rawBody);
    if (!verifyHmac(headers["x-stride-signature"], body, secret)) return null;
    if (keySet !== null && !verifyEd25519(headers["x-stride-audit-signature"], body, destinationId, keySet)) {
      return null;
    }
    if (bodyFormat === "json") {
      const batch = JSON.parse(body.toString("utf8"));
      if (batch === null || typeof batch !== "object" || batch.destination_id !== destinationId) return null;
      if (organizationIdOf(batch) !== organizationId) return null;
      events = batch.events;
    } else {
      events = body
        .toString("utf8")
        .split("\n")
        .filter((line) => line.trim() !== "")
        .map((line) => JSON.parse(line));
    }
  } catch (error) {
    return null;
  }
  if (!Array.isArray(events) || !events.every((event) => isEventOf(event, organizationId))) return null;
  const newEvents = events.filter((event) => !seen.has(`${event.instance}/${event.id}`));
  newEvents.forEach((event) => seen.add(`${event.instance}/${event.id}`));
  return newEvents;
}
```

`accept` returns `null` for every refusal, including a body that
`zlib.gunzipSync` can't inflate within `maxOutputLength`. Answer it as for the
Python example.

## Lag and a held horizon

**Behind by** on the list and on the destination page says how far a
destination is behind: "Up to date", or how many events are waiting and how
old the oldest one is.

Stride sends an event only once every transaction that started before it has
finished, so that an event committed late is never skipped. The point it
waits for, the **horizon**, is the oldest transaction still running anywhere
on the **database server**, in any database, not only Stride's. A
transaction that stays open for a long time therefore holds back every
destination of every Organization. Events held this way count as waiting, so
a held horizon shows as a growing number of waiting events and a growing
age, never as "Up to date".

Only a transaction that has written something, and so has a transaction id,
holds the horizon. A read-only session that is idle in a transaction does
not. When every destination falls behind together, look first at:

- `pg_stat_activity` rows, in **any** database on the server, with a
  `backend_xid` and an old `xact_start`, such as a long batch job, a
  `CREATE INDEX CONCURRENTLY`, a `VACUUM FULL` or a long migration:

  ```sql
  SELECT datname, pid, backend_xid, xact_start, state, left(query, 80)
  FROM pg_stat_activity
  WHERE backend_xid IS NOT NULL
  ORDER BY xact_start;
  ```

- `pg_prepared_xacts`, where a forgotten prepared transaction can hold the
  horizon indefinitely:

  ```sql
  SELECT gid, prepared, owner, database FROM pg_prepared_xacts ORDER BY prepared;
  ```

Operators can follow lag over time with the
`audit_stream.lag_measured.lag_seconds` metric; see
[Audit log streaming events](telemetry.md#audit-log-streaming-events).

## When deliveries fail

A destination's state is one of:

| State | Meaning |
|---|---|
| **Healthy** | Its last delivery succeeded |
| **Retrying** | A delivery failed and will be tried again |
| **Failing** | Deliveries have kept failing for 30 minutes since the first failure, or the destination answered in a way that a retry can't fix |
| **Paused** | An org-admin chose **Pause** on its row. **Resume** starts it again from where it stopped |
| **Needs attention** | Stride has stopped sending until a person acts; the page says why |

- **Retried:** a timeout, a connection that fails, a host that does not
  resolve, HTTP `408`, `429` and any `5xx`. Stride waits 15 seconds after the
  first failure, then doubles the wait each time up to 15 minutes, with up to
  20% added at random. A `Retry-After` in seconds is honoured up to an hour.
  A collector that refuses Stride's addresses shows "Could not connect to the
  destination" and is retried like any other connection failure.
- **Failing at once:** credentials refused (HTTP `401` or `403`, or a Splunk
  token error), or a Splunk setting problem. Stride keeps trying, so the
  destination recovers on its own once the token or setting is fixed.
- **Too large:** HTTP `413` halves the batch and sends it again, down to a
  single event.
- **Rejected:** any other answer is a rejection of the batch. Stride tries the
  same batch three times, 5 minutes apart, then stops with **Needs
  attention**.

**Recent attempts** on the destination page lists the last 50 attempts,
newest first, with their outcome, HTTP status and error. The error names the
status or says that Stride could not connect; it never quotes the
destination's answer. Attempts are kept for 7 days, and at most 200 per
destination.

### Needs attention

A destination that needs attention sends nothing until its cause is fixed.
Its events wait in the audit log, so nothing is lost while the log keeps
them (see [Gaps](#gaps)). The page shows one of:

| Reason | What to do |
|---|---|
| "The destination rejected the same batch on every try. Stride never skips a batch on its own: fix the cause at the destination and choose Retry now, or skip the batch." | Fix the cause, then choose **Retry now** or **Skip this batch** |
| "The URL's host resolves only to addresses Stride may not send to. Nothing is sent until the URL is changed." | Edit the destination and enter a URL whose host is on the public internet |
| "The database was moved. An operator must re-seed audit streaming." | Ask your Stride operator; see [After a logical database move](#after-a-logical-database-move) |
| "Credentials can't be read. Enter them again." | Choose **Enter the credentials again**; see [A lost or replaced ENCRYPTION_KEY](#a-lost-or-replaced-encryption_key) |

### Retry now and Skip this batch

Both are offered only for a rejected batch. **Retry now** sends the same
batch again, under the same `batch_id`, straight away. **Skip this batch** gives
up on it: the destination moves past exactly that batch and carries on. A
skipped batch's events are not sent to that destination, and stay in the
audit log and in exports. A skip is recorded as an attempt with the outcome
**Skipped** and as the `audit_stream_batch_skipped` audit event, which every
destination receives.

Neither is offered for a Splunk setting problem or refused credentials,
which would fail the same way for every batch: fix the token or setting, and
the next delivery recovers.

### Test events

A test event is a single event with the id `0`, the action
`audit_stream_test_sent`, empty metadata and no actor. It is sent when the
form is saved and when an org-admin chooses **Send test event**, and the
result is shown at once, such as "Test event delivered", "Could not connect",
"The certificate could not be verified" or "The destination refused the
credentials". Each test is recorded as the `audit_stream_test_sent` audit
event.

Every test event has the same id, `0`, so a receiver that drops duplicates
by `instance` and `id` treats each test after the first as a duplicate. That
is harmless when the receiver still answers 2xx, as the samples above do, but
it means a test event never reaches storage twice. If you count deliveries,
or want each test stored, check the action before the duplicate check and
handle `audit_stream_test_sent` on its own: never add it to the set of ids
you have seen.

An Organization can send 10 test events an hour, across all its
destinations and org-admins. The count runs per clock hour, so up to 20 can
go out across an hour boundary, and it is kept per server node.

## Gaps

A gap is a run of events that a destination will never receive. It is
listed under **Gaps** on the destination page, with its reason, how many
events it holds, and the time of its first and last event. The events stay
in the audit log: export that time range from the Organization's audit page,
load it into the tool, then **Dismiss** the gap.

| Reason | Cause |
|---|---|
| "Deleted by retention before it was sent" | The Organization's [audit retention](organization-security-policies.md#audit-retention) deleted events the destination had not received. Retention does not wait for a destination to catch up |
| "Too old for Datadog" | Events older than 17 hours when they would have been sent to Datadog |
| "Left behind by a database move" | Events a re-seed could not send after a logical database move |

The daily retention purge first takes each destination's lease, waiting up
to 30 seconds. If a delivery still holds one, that Organization's purge is
skipped for the day and runs the next day, so events can be kept a day
longer than the retention period, never deleted early.

Opening a gap records the `audit_stream_gap` audit event, and a gap that
keeps growing records it again at most once a day, so the tools see the loss
too. Every org-admin is also emailed; see
[Emails to org-admins](#emails-to-org-admins).

## Emails to org-admins

Every enabled org-admin of the Organization is emailed, in the language they
chose for Stride (English if none), when:

| Email | Sent when |
|---|---|
| Created | A destination is created. When it starts from an earlier point than now, the subject names the catch-up: "catching up the last 24 hours", "the last 7 days", "the last 17 hours", or "sending the whole audit log" |
| Changed | Its URL, token, API key or header value, **Include email and IP addresses**, the excluded actions, the Splunk index, the Datadog site, service or tags, or the HTTPS authorization header name changes. The email lists what changed. Renaming a destination, or changing only the Splunk source type or the HTTPS format, sends no email |
| Paused, resumed | **Pause** or **Resume** changes it. Choosing it again on a destination already paused or running sends no email |
| Deleted | A destination is deleted |
| Failing | It becomes **Failing**, at most once an hour. A Datadog destination's email says that events not delivered within 17 hours are lost. When its credentials can't be read, the email asks an org-admin to enter them again, also when the destination was already Failing |
| Recovered | It goes from Failing back to Healthy, at most once an hour |
| Re-seed | Transaction ids went backwards after a database move, so an operator must re-seed; see [After a logical database move](#after-a-logical-database-move) |
| Gap | A [gap](#gaps) opens, and then at most once every 7 days while it grows |

Each email names who acted, or says that Stride recorded it, and the
destination's name, type, host and last 4 characters, and links to its page.
None contains the destination's URL, token, API key, header value or signing
secret. They are security emails, so they are sent whatever an org-admin's
notification settings are and have no unsubscribe link. The org-admin who
made a change receives the email too, so a change made by one org-admin is
seen by all of them. Rotating a signing secret sends no email.

## Limits

| Limit | Value |
|---|---|
| Destinations per Organization | 3, unless the operator changes it with `AUDIT_STREAM_MAX_DESTINATIONS`. At the limit, **Add destination** is disabled |
| Events per batch | 500, and at most 900,000 bytes of request body before compression, as each type writes it |
| Test events | 10 an hour per Organization |
| Destination name | 80 characters, unique in the Organization ignoring case, so "Splunk" and "splunk" are the same name |
| URL | 2,048 characters |
| Token, API key or header value | 4,096 characters |
| Datadog tags | 90, of at most 200 characters each |
| Datadog service and Splunk source type | 100 characters |
| Datadog event age | 17 hours |
| Attempts shown | The last 50; kept for 7 days, at most 200 per destination |

## For operators

### AUDIT_STREAM_MAX_DESTINATIONS

The most destinations each Organization can have. It must be a whole number
from 1 to 50; unset or blank means 3. Any other value stops the app at boot
with "AUDIT_STREAM_MAX_DESTINATIONS must be a whole number from 1 to 50."
Lowering it never removes a destination: an Organization over the new limit
keeps its destinations and can't add another.

### Keep one machine running on Fly

The minute sweep starts every delivery and retry. On Fly, a machine that is
stopped while idle (`auto_stop_machines = 'stop'` with
`min_machines_running = 0`) runs no sweep, so nothing is delivered until a
visitor starts it again. Set `min_machines_running = 1` in the app's Fly
configuration when Organizations stream their audit log, at the cost of one
machine that is always on.

### After a logical database move

Streaming remembers each destination's position by Postgres transaction id,
and those ids belong to one database server. After a dump and restore, a
logical replication switch-over or a major-version upgrade done by dump,
every destination stops with "The database was moved. An operator must
re-seed audit streaming." A physical replica or a Fly Managed Postgres
failover keeps the ids and needs nothing. Drain the destinations before the
move and re-seed them after it with `Kanban.Release.reseed_audit_stream_cursors/0`,
as the runbook in
[Re-seeding audit streaming after a logical database move](audit-log-database-roles.md#re-seeding-audit-streaming-after-a-logical-database-move)
describes.

### Don't use Kanban.AuditLog.purge_before/1

`Kanban.AuditLog.purge_before/1` deletes old audit events for **every**
Organization and records no gaps, so a destination silently never receives
what it deleted. Never use it while any destination exists. The daily
retention job, which follows each Organization's audit retention period,
records a gap for every event a destination loses.

### A lost or replaced ENCRYPTION_KEY

Destination URLs, tokens, API keys, header values and signing secrets are
stored encrypted with `ENCRYPTION_KEY`. If that key is lost or replaced, the
streaming pages and the sweep keep working, but a destination whose secrets
can no longer be read stops with **Needs attention** and "Credentials can't
be read. Enter them again." It sends nothing and records no attempt, and its
test events are refused. The list and the destination page still show its
host and last 4 characters.

Nothing is lost while the audit log keeps the events: once the secrets are
entered again, the destination carries on from where it stopped. Audit
retention still applies meanwhile, so an Organization with a retention
period can lose events to a [gap](#gaps) if the destination stays stopped
long enough.

To recover, an org-admin of each affected Organization chooses **Enter the
credentials again**, enters the URL and the token, API key or header value
again (a Datadog destination has no URL), and saves. For an HTTPS endpoint they also choose **Rotate signing
secret**, which makes a new secret at once with no 24-hour overlap, since the
old one can't be read, and update the receiver with the new secret.

### The signing key

HTTPS batches are signed with Ed25519 by the instance's audit signing key,
the same key that signs exports, from `AUDIT_SIGNING_KEY`. With no signing
key, batches carry only the HMAC `x-stride-signature`.
[Setting up the signing key](audit-log-signed-exports.md#setting-up-the-signing-key),
[Rotating the key](audit-log-signed-exports.md#rotating-the-key) and
[Revoking a leaked key](audit-log-signed-exports.md#revoking-a-leaked-key)
cover the key. Receivers choose the key by `kid`, and a previous key stays in the key set
after a rotation, so a receiver only needs to fetch the key set again.

### Telemetry

The streaming worker emits four telemetry events, which carry the
destination's type and a fixed outcome or reason only, never an Organization
id, a URL, a host, a name or an email. See
[Audit log streaming events](telemetry.md#audit-log-streaming-events).
