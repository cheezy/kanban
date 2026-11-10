# Audit Log Streaming — Implementation Design

**Roadmap item:** *Audit log streaming*, under *Planned*: "Send the audit log to a security tool such as Splunk, Datadog or a SIEM, and sign audit exports." ([ROADMAP](../../ROADMAP.md))

**Status:** Proposed design, not yet decomposed into tasks. Every decision in [§15](#15-decisions-needed) was settled on 2026-11-10: D1 to D8 before the exploratory review, and D9 to D15 after it.

**Date:** 2026-11-09. Revised on 2026-11-10 to record the decisions, and again on 2026-11-10 to apply the corrections from an exploratory review of this document. That review's eight session reports and summary are kept outside the repo, in `.exploratory/audit-streaming-design/`. The main changes after the review:

- delivery uses a committed lease and a stored next-attempt time instead of an advisory lock held across the POST, and there is no after-commit nudge;
- a time-window start point filters by time instead of placing the cursor;
- Datadog's 18-hour limit and Splunk's error codes are handled;
- retention gaps have their own table and a defined, ordered procedure;
- personal data is removed from `metadata` as well;
- changes to the actions a destination leaves out are emailed;
- the Organization payload uses `id` and `name`, as there is no slug;
- the tasks are re-cut, with every cross-goal dependency listed.

This document describes how an Organization sends its audit log, as it
happens, to the security tools it already uses, and how anyone can prove that
an audit export downloaded from Stride has not been changed. It covers the
destinations Stride supports, how events are read from the database without
skipping or reordering any, what each delivery looks like, the screens
org-admins use, the signing of exports, the security rules, the tests, and the
work broken into goals and tasks.

**Streaming is an Organization feature.** It sends the Organization audit log,
which only Organizations have, and only an org-admin can set it up. It needs
no new plan check: the page sits behind the same org-admin gate as the
Organization audit log ([§4](#4-access-and-the-plan-gate)).

**Stride pushes; nothing pulls.** Stride sends events to the destination over
HTTPS. No destination ever connects to Stride, and no new inbound API is
added.

---

## Table of contents

1. [Goals and non-goals](#1-goals-and-non-goals)
2. [What already exists that streaming builds on](#2-what-already-exists-that-streaming-builds-on)
3. [Streaming at a glance](#3-streaming-at-a-glance)
4. [Access and the plan gate](#4-access-and-the-plan-gate)
5. [Destinations](#5-destinations)
6. [The event payload](#6-the-event-payload)
7. [Reading events in commit order](#7-reading-events-in-commit-order)
8. [Delivery](#8-delivery)
9. [Data model](#9-data-model)
10. [Screens](#10-screens)
11. [Signed audit exports](#11-signed-audit-exports)
12. [Security](#12-security)
13. [Telemetry, audit events, notifications and docs](#13-telemetry-audit-events-notifications-and-docs)
14. [Testing strategy](#14-testing-strategy)
15. [Decisions needed](#15-decisions-needed)
16. [Goals, tasks and order](#16-goals-tasks-and-order)
17. [Risks](#17-risks)

---

## 1. Goals and non-goals

### Goals

- An org-admin can send the Organization audit log to **Splunk**, **Datadog**,
  or **any HTTPS endpoint**. The HTTPS option covers Sumo Logic, Google
  Security Operations, Elastic through Logstash, Microsoft Sentinel through a
  Logic App, and in-house collectors.
- Every event reaches every enabled destination **at least once**, **in commit
  order**, usually **within about a minute** of happening.
- **No event is skipped without a record.** That holds even when an event's
  transaction commits after events with later ids, and even when a
  destination is down for days. The only ways an event can fail to arrive are
  ones Stride records and tells org-admins about: retention removing it first,
  Datadog's 18-hour limit, and an org-admin choosing **Skip this batch**
  ([§8.6](#86-retention-and-a-destination-that-falls-behind), [§8.4](#84-retries-and-failure)).
- A destination that fails is **retried, not dropped**. Events wait in the
  audit log itself until the destination recovers. Org-admins see how far
  behind it is and why it is failing, and are emailed when it starts failing.
- A new destination can **start now** or **catch up** on events the audit log
  still holds.
- Destinations get the **same redaction** as the Organization audit log page.
  An actor from outside the Organization is never identified.
- Adding, changing, pausing or deleting a destination is **itself an audit
  event**, and every org-admin is emailed about it.
- **Audit exports can be signed.** A signed export comes with a manifest and
  an Ed25519 signature that anyone can verify with OpenSSL 3 or a short Python
  script, against a public key Stride publishes.
- **Streamed batches are signed too.** A batch sent to an HTTPS endpoint
  carries an HMAC, in the webhook format, and an Ed25519 signature made with
  the same published key as exports.

### Non-goals (for this roadmap item)

- **The site audit log.** Events with no Organization, which Stride's own site
  admins see at `/admin/audit-log`, are not streamed. A self-hosting operator
  who wants them can read the `security_audit` log line Stride already writes
  for every event.
- **Other transports.** Syslog over TLS, Kafka, Amazon S3 or another object
  store, and the native Microsoft Sentinel Logs Ingestion API (which needs
  Azure AD OAuth) are later candidates. Each would be a new destination
  adapter ([§5.4](#54-adding-a-destination-type-later)).
- **Choosing events by condition.** A destination sends every action, less an
  optional list of actions to leave out. Queries and conditions on metadata
  are the destination tool's job.
- **Hash-chaining the stored audit log.** The log is append-only today
  ([audit log hardening](../audit-log-hardening.md)). A hash chain over the
  stored rows would add tamper evidence inside the database. That is a
  separate piece of work, described in [§11.7](#117-later-a-hash-chain-over-the-stored-log).
- **An API for destinations.** Destinations are managed in the Organization
  console only. There is no org-admin API token today, and this item does not
  add one.
- **Changing how events are recorded.** `Kanban.AuditLog.event/2` keeps its
  contract and its code. Streaming reads what it stores. The only change on
  the recording side is the new `txid` column, which the database fills in
  ([§9.1](#91-a-commit-order-column-on-audit_events)). That is why there is no
  after-commit nudge ([§8.1](#81-workers-and-scheduling), D9).
- **Static egress addresses.** Stride does not publish a fixed list of the
  addresses it sends from, so a collector that only accepts listed addresses
  is not supported in this item ([§12.1](#121-sending-to-the-internet-safely), D14).

---

## 2. What already exists that streaming builds on

| Piece | Where | What streaming uses it for |
| --- | --- | --- |
| The `audit_events` table | `lib/kanban/audit_log/audit_event.ex`, migrations from `20261006102406` | The source of every streamed event. It is append-only, and its `organization_id` column scopes each row to an Organization |
| Append-only enforcement and ownership hardening | `lib/kanban/audit_log/hardening.ex`, [audit-log-hardening.md](../audit-log-hardening.md), [audit-log-database-roles.md](../audit-log-database-roles.md) | Rows cannot change after they are read, so a delivered event never goes stale. That holds fully on a hardened database. Production runs Fly Managed Postgres, which stays in degraded mode, where the app role owns the table ([§9.1](#91-a-commit-order-column-on-audit_events)) |
| Outside-actor redaction | `lib/kanban/audit_log/organization_scope.ex` | Applied to every streamed event, as on `/org/audit` |
| The export row shape | `Kanban.AuditLog.Export.row_map/1` | The source of the streamed payload's values. The payload renames and regroups them, as [§6](#6-the-event-payload) lists |
| The org audit export | `lib/kanban_web/controllers/org_audit_log_export_controller.ex` | The endpoint that gains a signed variant ([§11](#11-signed-audit-exports)) |
| Retention | `lib/kanban/retention/purge_worker.ex`, `Kanban.AuditLog.purge_organization_before/3`, `audit_retention_days` on the security policy | Interacts with a destination that falls behind ([§8.6](#86-retention-and-a-destination-that-falls-behind)) |
| Webhook delivery | `lib/kanban/webhooks/` | `UrlGuard` (SSRF protection) and `Transport` (Req pinned to the approved IP, no redirects, capped response) are reused as they are. `Signer` (HMAC-SHA256 `X-Stride-Signature`) gains a way to sign with a list of secrets, because a streaming rotation sends two `v1` values ([§5.3](#53-any-https-endpoint)); webhooks keep calling it with one |
| Encryption at rest | `Kanban.Encryption` and `Kanban.Encryption.EncryptedBinary` (AES-256-GCM, key from `ENCRYPTION_KEY`) | Destination URLs and credentials, as for the SSO client secret |
| The org-admin gate | `KanbanWeb.UserAuth` `on_mount :require_org_admin`, and a private `with_org_admin/2` copied into each Organization console page (`OrgLive.Console`, `Security`, `SSO`, `SCIM`) | The new pages and their events. B1 moves `with_org_admin/2` into one shared module first, so the new pages do not add two more copies ([§16](#16-goals-tasks-and-order)) |
| Notifications | `Kanban.Notifications`, its email worker and per-recipient locale (`Gettext.with_locale` per user) | The translated org-admin emails ([§13.3](#133-emails)). `Kanban.Accounts.UserNotifier` is not used: it has no translations |
| Oban | `config/config.exs` | A new `:audit_stream` queue and two cron entries: `AuditStream.Scheduler` every minute and `AuditStream.AttemptPruneWorker` every hour |
| Telemetry | `Kanban.Telemetry.emit/3`, `Kanban.Telemetry.Catalog` | Delivery events and the new audit actions ([§13](#13-telemetry-audit-events-notifications-and-docs)) |

The `:audit` plan feature is declared in `Kanban.Plans` but nothing checks it
today. [§4](#4-access-and-the-plan-gate) explains why streaming does not need
it either.

---

## 3. Streaming at a glance

```text
 Kanban.AuditLog.event/2
        │  inserts a row; the database sets txid to the inserting transaction's id
        ▼
 audit_events
        │
        │ every minute: sweep
        ▼
 AuditStream.Scheduler ── one DispatchWorker job per destination that is due and has events waiting
        │
        ▼
 AuditStream.DispatchWorker (queue :audit_stream)
   1. take the destination's lease: a short, committed update of its cursor row
   2. re-read the pending batch, or cut the next one after the cursor from
      committed rows only (§7), and record it as pending; commit
   3. redact, filter and encode it for the destination (§5, §6)
   4. POST it through UrlGuard + Transport, with no transaction open (§8)
   5. on 2xx: advance the cursor and record the attempt; if more is waiting, go again (paced)
      otherwise: record the attempt, keep the cursor, set the next attempt time
   6. release the lease
```

There is no outbox table and no copy of the events. The audit log is the
queue, and each destination keeps only a cursor into it. A destination that is
down for a week simply has an older cursor; when it recovers, it catches up
from where it stopped, unless retention or Datadog's age limit has removed
events first, which is recorded as a gap ([§8.6](#86-retention-and-a-destination-that-falls-behind)).

---

## 4. Access and the plan gate

- **Who.** Only an enabled org-admin of the Organization can see or change its
  destinations, or download a signed export. The pages use
  `on_mount {KanbanWeb.UserAuth, :require_org_admin}` and re-read the role
  from the database on every event with `with_org_admin/2`, like
  `OrgLive.Security`. The Organization's two-factor requirement applies, as it
  does to every `/org` page.
- **The plan.** An Organization is the paid plan, so every Organization can
  stream. No new plan feature is needed. If the `:audit` feature is ever wired
  up, the page checks it with surface `:live_view`, and the worker checks it
  with surface `:oban` before each delivery, which pauses the destination
  without losing its cursor.
- **Site admins.** Stride's own site admins cannot see or change an
  Organization's destinations, as with the rest of the Organization console
  ([§15](#15-decisions-needed), D8).
- **Leaving the Organization.** Destinations belong to the Organization, not
  to the org-admin who created them. One org-admin leaving does not pause
  anything, unlike webhooks, which belong to the person who added them.
- **Deleting the Organization.** Its destinations, cursors, gaps and attempt
  history are deleted with it (`on_delete: :delete_all`).

---

## 5. Destinations

An Organization can have up to **3 destinations** (`AUDIT_STREAM_MAX_DESTINATIONS`,
default 3), for example one SIEM and one archive. `config/runtime.exs` reads
the variable and stops the boot, naming it, when it is not a whole number from
1 to 50. Each destination has a type, a name the org-admins choose, and the
settings below.

Every type's display shows the host **and** the last 4 characters of its
credential (or, for an HTTPS URL that carries its own token, of the URL), so
two destinations on a shared collector host can be told apart
([§12.3](#123-abuse-by-an-org-admin)).

### 5.1 Splunk (HTTP Event Collector)

| Setting | Notes |
| --- | --- |
| HEC URL | The collector address. The path must be `/services/collector` or `/services/collector/event`. Anything else is refused, because `/services/collector/raw` would index each line as raw text. Splunk Cloud has three host forms: `http-inputs-<stack>.splunkcloud.com` on AWS, `http-inputs.<stack>.splunkcloud.com` on Google Cloud and Azure, and `http-inputs.<stack>.splunkcloudgc.com` for FedRAMP. A `*.splunkcloud.com` or `*.splunkcloudgc.com` host without `http-inputs` gets a warning that it is probably the web address, not the collector. Self-managed Splunk usually listens on port 8088. Must be HTTPS with a certificate that verifies; there is no option to skip verification, so Splunk Cloud **trial** stacks, whose collectors use self-signed certificates, are not supported |
| HEC token | Sent as `Authorization: Splunk <token>`. Stored encrypted; shown afterwards only as its last 4 characters. The token must have **indexer acknowledgement turned off**, and the form says so |
| Index | Optional. Left out of the event when blank, so the token's default index applies |
| Source type | Default `stride:audit` |

**Request.** `POST` with `Content-Type: application/json` and
`Content-Encoding: gzip`. The body is the events one after another, each as a
HEC event object, which is the HEC batch format:

```json
{"time":1794193366.015,"host":"stridelikeaboss.com","source":"stride","sourcetype":"stride:audit","event":{...}}
{"time":1794193367.200,"host":"stridelikeaboss.com","source":"stride","sourcetype":"stride:audit","event":{...}}
```

`time` is the event's `occurred_at` in epoch seconds with milliseconds. `event`
is the payload from [§6](#6-the-event-payload).

**Responses.** Splunk puts a numeric `code` in the body, and the adapter
classifies on that code as well as the status, because several configuration
faults come back as HTTP 400:

| Answer | Classification |
| --- | --- |
| Any 200, including code 0 and codes 24 and 25 (a queue nearing capacity) | Success. Codes 24 and 25 are logged as a warning and never retried, since the batch was accepted |
| 400 with code 5, 6, 12, 13 or 15 (bad event data) | Permanent rejection of this batch ([§8.4](#84-retries-and-failure)). A 400 can carry `invalid-event-number`; the attempt's error records it, and the destination page warns that the events before it may already be indexed |
| 400 with code 7 (incorrect index), 10 or 11 (data channel missing or invalid, which means indexer acknowledgement is on), 14 (acknowledgement disabled) or 16 (query-string authorization) | Configuration error. The destination is **Failing** at once, with a reason naming the fix, such as "Turn off indexer acknowledgement on this HEC token" or "The token can't write to index *x*". No **Skip this batch** is offered, because every batch would fail the same way |
| 400 with code 21 or 22, 401, 403 | Unauthorized: the token is wrong or disabled |
| 413 | Halve the batch and try again ([§8.2](#82-batches)) |
| 429 (codes 26 and 27), 503 (codes 9, 18 to 20 and 23), other 5xx | Retried, honouring `Retry-After` |

Indexer acknowledgement is not used. Stride never sends an
`X-Splunk-Request-Channel` header.

### 5.2 Datadog (Logs intake)

| Setting | Notes |
| --- | --- |
| Datadog site | One of `datadoghq.com`, `us3.datadoghq.com`, `us5.datadoghq.com`, `datadoghq.eu`, `ap1.datadoghq.com`, `ap2.datadoghq.com`, `uk1.datadoghq.com`, `ddog-gov.com`, `us2.ddog-gov.com`. Stride builds the URL `https://http-intake.logs.<site>/api/v2/logs` from it, so no free-form URL is entered. The list is fixed in code and must be kept in step with Datadog's list of sites |
| API key | Sent as `DD-API-KEY`. Stored encrypted; shown afterwards only as its last 4 characters |
| Service | Default `stride-audit` |
| Tags | Optional `key:value` pairs added to `ddtags`, after `source:stride` and `organization_id:<id>`. At most 90 tags of at most 200 characters each, which keeps every entry inside Datadog's limit of 100 tags of 256 characters |

**Request.** `POST` with `Content-Type: application/json` and
`Content-Encoding: gzip`. The body is a JSON array of log entries:

```json
[{"ddsource":"stride","service":"stride-audit","hostname":"stridelikeaboss.com",
  "ddtags":"source:stride,organization_id:210",
  "date":1794193366015,
  "message":"Member removed by alex@northwind.example",
  "stride":{...}}]
```

- `date` is the event's `occurred_at` in epoch milliseconds. Datadog uses it
  as the log's time; without it, every delayed or caught-up event would show
  at the time Stride sent it.
- `stride` holds the payload from [§6](#6-the-event-payload), so Datadog
  indexes its fields as attributes.
- `message` is a short English line for the log list. It is built from the
  payload **after** redaction and the personal-data setting
  ([§6](#6-the-event-payload)): "*action label* by *email*" when the email is
  in the payload, otherwise "*action label* by user *id*", otherwise the label
  alone.

Datadog takes at most 1,000 entries and 5 MB uncompressed per request. An
entry over 1 MB is truncated, not refused. A Stride batch stays well inside
all three ([§8.2](#82-batches)).

**Datadog's 18-hour limit.** Datadog drops any log entry whose time is more
than 18 hours in the past, and still answers 202 for the request. So Stride
never sends Datadog an event older than **17 hours** (an hour of margin):

- a Datadog destination can start **from now** or **from the last 17 hours**,
  and nothing older ([§8.5](#85-starting-point-and-catch-up));
- when a batch is cut, events older than 17 hours are not sent. They are
  recorded as a gap with the reason "too old for Datadog", exactly as
  retention gaps are ([§8.6](#86-retention-and-a-destination-that-falls-behind)),
  and the cursor moves past them;
- the email when a Datadog destination becomes Failing says that events are
  lost after it has been failing for 17 hours.

Datadog previews a longer window for some accounts; it is not relied on.

**Responses.** 202 is success. 408, 429 and 5xx are retried. 413 halves the
batch and tries again. 400 is handled as in [§8.4](#84-retries-and-failure).
401 (no API key) and 403 (invalid API key) are unauthorized; the destination
goes to *Failing* at once.

### 5.3 Any HTTPS endpoint

For every other tool. The endpoint receives Stride's own format. Its HMAC uses
the Stride webhook signature format, and it can be checked with the webhook
verifier once the body is decompressed.

| Setting | Notes |
| --- | --- |
| URL | HTTPS. Treated as a secret, because tools such as Sumo Logic put their token in the URL: stored encrypted, and shown afterwards as its host and the URL's last 4 characters |
| Format | **JSON batch** (default) or **NDJSON**, one event per line. Sumo Logic and Google Security Operations prefer NDJSON |
| Authorization header | Optional header name and value, such as `Authorization: Bearer …` or `X-goog-api-key: …`. The value is stored encrypted and shown afterwards only as its last 4 characters. These names are refused, case-insensitively, because Stride sets them: `Content-Type`, `Content-Encoding`, `Content-Length`, `Host`, `User-Agent`, `X-Stride-Signature`, `X-Stride-Audit-Signature`, `X-Stride-Batch`, `X-Stride-Event-Count`, `X-Stride-Destination` |
| Signing secret | Generated by Stride (`assec_` followed by 32 random bytes, base64url). The whole string, prefix included, is the HMAC key, as `whsec_…` is for webhooks. Shown once, when the destination is created, and again only when an org-admin rotates it |

**Request.** `POST` with `Content-Type: application/json` (or
`application/x-ndjson`), `Content-Encoding: gzip`, and these headers. The
adapter gzips the body and sets `Content-Encoding` itself; `Transport` sends
the bytes it is given.

| Header | Value |
| --- | --- |
| `X-Stride-Signature` | `t=<unix seconds>,v1=<hex HMAC-SHA256(secret, "<t>.<body>")>`, the webhook format. Unlike webhooks, whose rotation takes effect at once, a rotation here keeps the old secret valid for 24 hours. During that time the header carries one `v1=` per secret, the old one first, until `previous_secret_expires_at` |
| `X-Stride-Audit-Signature` | `t=<unix seconds>,kid=<key id>,ed25519=<signature>`. The signature is the 64-byte Ed25519 signature over `"<t>.<destination id>.<body>"`, made with the instance's audit signing key ([§11.4](#114-keys)), and written as base64url **without padding** (RFC 4648 §5). `t` is the same value as in `X-Stride-Signature`. Left out when the instance has no signing key |
| `X-Stride-Destination` | The destination's id, which the Ed25519 signature covers |
| `X-Stride-Batch` | The batch id, the same on every retry of the same batch |
| `X-Stride-Event-Count` | How many events the batch holds |
| `User-Agent` | `Stride-AuditStream/1` |

`<body>` in both signatures is the **decompressed** body, the JSON or NDJSON
text before gzip. A receiver inflates the request first (many frameworks do
this for it; it should check that its own does), then verifies the inflated
bytes. A receiver that already checks Stride webhooks reuses the code in
[Verify the signature](../webhooks.md#verify-the-signature) on those inflated
bytes, and splits each header part on its first `=` only.

The JSON batch format is:

```json
{"version":1,"batch_id":"5f0c…","destination_id":31,"organization":{"id":210,"name":"Northwind Studio"},"events":[{...},{...}]}
```

Each batch is signed twice, and a receiver can check either signature or both
([§15](#15-decisions-needed), D5):

- **The HMAC** proves the batch came from someone who holds this
  destination's secret, so it was meant for this endpoint.
- **The Ed25519 signature** proves the batch came from this Stride instance,
  and needs no shared secret: the receiver checks it against the public key
  Stride publishes ([§11.4](#114-keys)), choosing the key by `kid`. Unlike the
  HMAC, which the receiver could also have made with the shared secret, it can
  be kept with the events as evidence of where they came from. The key is the
  instance's, not the destination's, so a receiver also checks that
  `organization.id` is its own and that the signed destination id is its own,
  and drops a `batch_id` it has already accepted. To keep the signature as
  evidence, it stores the inflated body and the header unchanged. The 5-minute
  freshness check (reject a `t` more than 5 minutes from its own clock) applies
  when receiving, not when checking stored evidence later.

If the instance has no audit signing key, only the HMAC is sent, and the
destination's page says so.

**Responses.** Any 2xx is success. 408, 429 and 5xx are retried. 413 halves
the batch. 401 and 403 are unauthorized. Any other 4xx is handled as in
[§8.4](#84-retries-and-failure). Redirects are never followed.

### 5.4 Adding a destination type later

Each type is a module that implements a small behaviour:

```elixir
@callback validate(settings :: map()) :: :ok | {:error, keyword()}
@callback build_request(destination, [payload]) :: {url, headers, body}
@callback classify(status :: integer(), body :: binary()) ::
            :ok
            | {:retry, retry_after_seconds :: non_neg_integer() | nil}
            | :split
            | :permanent
            | :unauthorized
            | {:config_error, reason :: atom()}
@callback max_event_age() :: pos_integer() | :infinity
```

`max_event_age/0` is 17 hours for Datadog and `:infinity` for the others.
The worker owns reading, batching, retries, the cursor, telemetry and
attempts. A new type (syslog over TLS, S3, Sentinel) adds one module, its form
fields, and its tests.

---

## 6. The event payload

Every destination carries the same event object. Its values come from the
stored row through `Kanban.AuditLog.Export.row_map/1`, but the names and shape
differ, for a tool outside Stride:

```json
{
  "id": "1849230",
  "schema": "stride.audit.v1",
  "occurred_at": "2026-11-09T14:02:11.482913Z",
  "action": "org_member_removed",
  "action_label": "Member removed",
  "organization": {"id": 210, "name": "Northwind Studio"},
  "actor": {"user_id": 1153, "email": "alex@northwind.example", "in_organization": true},
  "ip": "203.0.113.24",
  "metadata": {"user_id": 1153, "organization_id": 210, "member_user_id": 1160},
  "instance": "stridelikeaboss.com"
}
```

| Payload field | From the row (`row_map/1` key) |
| --- | --- |
| `id` | `id`, as a string, so a 64-bit id survives JavaScript tools |
| `occurred_at` | `inserted_at` |
| `action` | `action` |
| `action_label` | New: the English label |
| `organization` | New: the Organization's `id` and current `name` |
| `actor.user_id` | `actor_user_id`, which falls back to `metadata.user_id` when the actor's account was deleted |
| `actor.email` | `actor_email` |
| `actor.in_organization` | New: from `actor_in_organization` |
| `ip` | `ip` |
| `metadata` | `metadata` |
| `schema`, `instance` | New |

- **`id`** with `instance` is unique across Stride, and receivers use it to
  drop a duplicate delivered twice ([§8.3](#83-at-least-once-and-batch-identity)).
- **`schema`** names the version. A field may be added within `v1`; renaming or
  removing one makes `v2`, and destinations created before that keep `v1`
  until an org-admin switches them.
- **`action_label`** is the label from `KanbanWeb.AuditLogActions`, which is a
  translated `pgettext` call. The payload builder calls it inside
  `Gettext.with_locale(KanbanWeb.Gettext, "en", …)`, so the label is English
  whatever locale is active when it runs, and searches in the tool stay
  stable.
- **`metadata.user_id`** is the actor, as everywhere in the audit log. The
  person acted on has their own key, such as `member_user_id`.
- **`actor`** follows the Organization audit page. For an actor from outside
  the Organization (`Kanban.AuditLog.OrganizationScope`):
  - `user_id`, `email` and the top-level `ip` are `null`;
  - the `user_id`, `email` and `ip` keys are **removed** from `metadata`, not
    set to `null`, so a detection must not expect them to be present;
  - `in_organization` is `false`.

  `in_organization` is always a boolean. For the few rows written before
  `actor_in_organization` existed, it is the same fallback the audit page uses,
  current membership.
- **`actor.email`** is the actor's email **now**, read from their account, not
  the email they had when the event happened, as on the audit page. A
  catch-up of old events therefore carries current emails. It is `null` when
  the account has been deleted.
- **`metadata`** is the stored, already-sanitised metadata
  ([§12.4](#124-what-is-never-sent)).
- **Personal data.** A destination can turn off **Include email and IP
  addresses**. Then `actor.email` and the top-level `ip` are `null`, and every
  `email` and `ip` key in `metadata` is removed, at any depth. The IP is stored
  twice, in the `ip` column and in `metadata`: 483 rows in development have
  `metadata.ip`, across 11 actions such as `login_failed`. `actor.user_id`
  stays, so events can still be linked together. Datadog's `message` is built
  after this step ([§5.2](#52-datadog-logs-intake)). The setting is on by
  default, because a SIEM is usually where these questions are answered.

---

## 7. Reading events in commit order

### 7.1 The problem

`audit_events.id` comes from a sequence, and `inserted_at` is set by the app.
Neither follows the order in which rows **commit**. `Kanban.AuditLog.event/2`
often runs inside the caller's transaction, so a row with id 100 can commit
after a row with id 101 has already been read and sent. A reader that keeps
"the highest id I have sent" would skip row 100 forever.

A time window ("only read rows older than 30 seconds") makes this rarer but
does not prevent it: a transaction can run longer than any window.

### 7.2 The approach: transaction ids and the snapshot horizon

Each row records the id of the transaction that inserted it, in a new column
`txid` ([§9.1](#91-a-commit-order-column-on-audit_events)). The reader only
looks at rows whose transaction is older than every transaction still running:

```sql
SELECT …
FROM audit_events
WHERE organization_id = $org
  AND txid < $horizon            -- pg_snapshot_xmin(pg_current_snapshot())::text::bigint
  AND (txid, id) > ($cursor_txid, $cursor_id)
  AND ($not_before IS NULL OR inserted_at >= $not_before)
ORDER BY txid, id
LIMIT $batch_size
```

`pg_snapshot_xmin` is the oldest transaction still in progress. Every
transaction older than it has finished, committed or rolled back, so the set
of rows below it can never grow again. The cursor `(txid, id)` therefore only
moves forward over rows that are final, and a row that commits late is simply
read once its transaction is below the horizon. No row is skipped, and none is
read twice except by a retry. `$not_before` is set only for a time-window
start point ([§8.5](#85-starting-point-and-catch-up)).

**The horizon is a parameter.** `Kanban.AuditStream.Reader` takes it as an
option, `:horizon`, which defaults to the `pg_snapshot_xmin` expression. A test
in the Ecto SQL sandbox runs inside one open transaction, and the rows it
inserts carry that transaction's id, which is never below its own horizon.
Tested this way, against a throwaway database: inside a transaction, its own
insert was invisible to the predicate, and it became visible after commit. So
sandboxed reader tests pass a horizon above their own transaction id. Only the
commit-order tests, in the throwaway race database, use the real one
([§14](#14-testing-strategy)).

This is a known Postgres pattern for transactional outboxes. It needs
Postgres 13 or later for `pg_current_xact_id()` and `pg_current_snapshot()`.
Production runs 13 or later, development 14 and CI 16, and streaming requires
it ([§15](#15-decisions-needed), D1).

### 7.3 What it costs

- **Lag follows the oldest open transaction on the whole database server.**
  The horizon is cluster-wide, not per database. Tested against a throwaway
  database: a transaction held open in a *second* database on the same server
  kept the newest row in the first database from being delivered. So review
  apps, CI test partitions or anything else sharing the server can hold back
  every destination.
  - **What holds it:** only a transaction that has a transaction id, which it
    gets on its first write, and is still open. A read-only
    idle-in-transaction session does not hold it. Long holders include a
    batch job writing in any database on the server, `CREATE INDEX
    CONCURRENTLY`, `VACUUM FULL`, long DDL, and a forgotten prepared
    transaction (`pg_prepared_xacts`), which can hold it indefinitely.
  - **How it shows:** the telemetry in [§13.1](#131-telemetry) reports events
    held above the horizon separately from events waiting below it, so a held
    horizon shows as a growing count rather than as "up to date".
  - **Where to look:** the documentation names, as the first things to
    check, `pg_stat_activity` rows with a `backend_xid` and an old
    `xact_start` in any database, and `pg_prepared_xacts`.
- **One index.** `(organization_id, txid, id)` keeps every read an index range
  scan.
- **Older rows.** Rows that exist before the migration get `txid = 0`
  ([§9.1](#91-a-commit-order-column-on-audit_events)), so they sort first, by
  id, and a catch-up reads them before anything new.
- **Transaction ids belong to one database server.** They do not carry over
  to a new server, so moving the database by dump and restore or logical
  replication needs the step in [§8.8](#88-after-a-database-move).

---

## 8. Delivery

### 8.1 Workers and scheduling

- **Queue.** A new Oban queue, `:audit_stream`, with a limit of 5. Oban
  applies the limit on each node, so an instance running *n* nodes runs at most
  5 × *n* sends at once.
- **`AuditStream.DispatchWorker`**: one job per destination. It is unique on
  the `destination_id` argument, with `period: :infinity` and the states
  `available`, `scheduled` and `retryable`. `executing` is left out on purpose,
  so a running job can queue its own follow-up. Uniqueness is only a way to
  avoid redundant jobs; the lease below is what prevents two parallel sends.
  Oban's unique check can drop an insert when it races another, and the sweep
  makes up for any job lost that way.
- **The lease.** A run first takes the destination's lease in one short,
  committed statement:

  ```sql
  UPDATE audit_stream_cursors
  SET lease_token = $token, leased_until = now() + interval '60 seconds'
  WHERE destination_id = $id
    AND (leased_until IS NULL OR leased_until < now())
  RETURNING …
  ```

  If no row comes back, another run holds the lease, and this one ends. The
  lease lasts longer than the longest POST (5 s to connect, 10 s to answer),
  with margin. Every later write by the run checks `lease_token`, so a run
  whose lease has expired can never move the cursor. There is no advisory
  lock, and no transaction is open during the POST, so the POST holds no pool
  connection and no transaction id and cannot hold back the horizon
  ([§7.3](#73-what-it-costs)). A run is three short transactions:
  1. take the lease, and cut or re-read the batch and record it as pending;
  2. the POST, outside any transaction;
  3. record the outcome, advance the cursor on success, and release or renew
     the lease.
- **Due.** The cursor stores `next_attempt_at`. A run for a destination that
  is not yet due ends at once.
- **Sweep.** `AuditStream.Scheduler`, an Oban cron job every minute, enqueues a
  dispatch job for every destination that is enabled, not halted
  (`halted_reason` is null), due (`next_attempt_at` is null or past) and has
  events waiting. The query lives in the `Kanban.AuditStream` context.
- **Draining.** A run that sends a batch and finds more waiting keeps going,
  for up to 30 seconds, then inserts its own follow-up job (possible because
  `executing` is not a unique state) and ends. A destination catching up is
  paced instead ([§8.5](#85-starting-point-and-catch-up)).
- **No nudge.** Events reach a destination at the next sweep, so within about a
  minute. An after-commit nudge was considered and dropped (D9).
  `Kanban.AuditLog.event/2` cannot tell when its caller's transaction commits.
  `Kanban.Telemetry.AfterCommit` only waits for a transaction its caller wraps
  in it, and inserting a job inside the caller's transaction could abort it.
  An `AFTER INSERT` trigger calling `pg_notify`, which Postgres delivers only
  on commit, is possible later. It is DDL on `audit_events`, so it would
  follow [§9.1](#91-a-commit-order-column-on-audit_events)'s rules.
- **Machines that stop.** `fly.production.toml` has
  `auto_stop_machines = 'stop'` and `min_machines_running = 0`. While the last
  machine is stopped, no cron runs, so the sweep, retries, catch-up and the
  move to **Failing** all wait for the next request that starts a machine.
  Events recorded just before it stopped, and those the nightly jobs record,
  wait with them. D15 keeps one machine running once streaming ships, so this does not happen in production.

### 8.2 Batches

A batch holds up to **500 events** and up to **900,000 bytes** of uncompressed
body, whichever comes first:

- Datadog takes 1,000 entries and 5 MB;
- Splunk Cloud and many HTTP collectors take 1,000,000 bytes, so a batch at
  exactly 1 MB would meet a 413 every time it was full;
- self-managed Splunk Enterprise allows far more by default.

A single event is never near either limit: metadata values are capped at 2,000
characters when they are stored.

A 413 from the destination halves the batch and tries again, down to a single
event. Each half is cut and recorded as a new pending batch in a later run,
never inside one transaction. A single event that still gets 413 is handled as
a permanent rejection ([§8.4](#84-retries-and-failure)). Datadog truncates an
over-large entry rather than refusing it, so it never sends this 413.

When a batch is cut for a type with a maximum event age (Datadog), events past
that age are left out and recorded as a gap ([§5.2](#52-datadog-logs-intake),
[§8.6](#86-retention-and-a-destination-that-falls-behind)).

### 8.3 At-least-once and batch identity

Delivery is **at least once**. The cursor moves only after the destination
answers 2xx, so a crash between the answer and the cursor update sends the
batch again. Every event carries its stable `id`, and every batch its
`batch_id`, so the receiver can drop duplicates.

To make a retry resend exactly the same events, the cursor row keeps the
**pending batch**: its `batch_id` and its first and last `(txid, id)`. It is
written and committed before the POST, so it survives a crash. A retry re-reads
exactly that range, even if more events have arrived meanwhile. A new batch is
cut only once the pending one has succeeded or been given up.

One thing can change a pending batch: retention removing some of its events.
The retention step then discards the pending batch and records the loss as a
gap. The next run cuts a new batch, with a new `batch_id`, from the events that
remain ([§8.6](#86-retention-and-a-destination-that-falls-behind)). A
`batch_id` therefore always names the same events.

### 8.4 Retries and failure

Backoff is computed from the destination's `consecutive_failures`, not from
Oban's attempt count, and stored as the cursor's `next_attempt_at`. The run
then inserts its follow-up job scheduled for that time, and the sweep skips
the destination until then. Retry-After and the 15-minute cap therefore hold
however often the sweep runs.

| Outcome | What happens |
| --- | --- |
| 2xx | Cursor moves past the batch. The attempt is recorded. `consecutive_failures` resets to 0 and `next_attempt_at` to null |
| Retryable (5xx, 408, 429, a timeout, a refused connection, a host that does not resolve) | The cursor stays. `next_attempt_at` is set 15 s × 2^`consecutive_failures` ahead, with up to 20% jitter, capped at 15 minutes. A `Retry-After` the destination sends is used when it is later, up to 1 hour |
| Unauthorized (401, 403, and Splunk codes 21 and 22) | The cursor stays. The destination is marked **Failing** at once and every org-admin is emailed. Delivery keeps trying at the capped interval, so it recovers by itself if the token is fixed at the tool's end |
| Configuration error (Splunk codes 7, 10, 11, 14, 16) | As unauthorized, with a reason naming the fix ([§5.1](#51-splunk-http-event-collector)). **Skip this batch** is not offered |
| Permanent rejection (another 4xx for the whole batch, or 413 for one event) | The batch is retried 3 times over about 10 minutes in case it was transient. Then the destination is marked **Failing**, `halted_reason` is set to `rejected_batch`, its cursor stays where it is, and every org-admin is emailed. Nothing more is sent until an org-admin either fixes the cause at the tool's end and chooses **Retry now**, or chooses **Skip this batch** on the destination's page ([§10.4](#104-the-destinations-page)). Either clears `halted_reason`. A skip records an attempt with outcome `skipped` and an `audit_stream_batch_skipped` audit event naming the events skipped, then delivery carries on. Stride never skips a batch on its own ([§15](#15-decisions-needed), D3) |
| Blocked address (`UrlGuard` refuses every address the host resolves to) | The destination is marked **Failing**, `halted_reason` is set to `blocked_address`, the reason is shown, and nothing is sent until the URL is changed, which clears it |
| Transaction ids went backwards ([§8.8](#88-after-a-database-move)) | The destination is marked **Failing** with `halted_reason` `txid_reset`, and nothing is sent until an operator re-seeds the cursors |

A destination is **Retrying** after its first failed attempt and **Failing**
after 30 minutes without a success. It becomes Failing at once on an
unauthorized answer, a configuration error, a blocked address or a `txid`
reset, and after the third try of a permanently rejected batch.
Org-admins are emailed when it becomes Failing and when it recovers, at most
once an hour each way. Nothing is ever turned off automatically. Events wait
in the audit log, and a Failing destination resumes where it stopped. A
halted destination (`halted_reason` set) is the one case that waits for a
person, because sending the same batch again would only be refused again.

### 8.5 Starting point and catch-up

When an org-admin creates a destination, they choose where it starts. Every
choice is recorded in the `audit_stream_destination_created` event and named
in the email to every org-admin ([§12.3](#123-abuse-by-an-org-admin)).

- **From now** (default): the cursor is set to `(h, 0)`, where *h* is
  `pg_snapshot_xmin` read inside the transaction that creates the destination.
  Every event whose transaction was still running at that moment, or started
  later, is sent. That includes a few events that committed just before the
  destination was created, and the destination's own
  `audit_stream_destination_created` event, which is its first event.
- **From the last 24 hours** or **the last 7 days**: the cursor is set to
  `(0, 0)` and `not_before` to the start of the window. The reader sends every
  event inserted inside the window, whatever its `txid`
  ([§7.2](#72-the-approach-transaction-ids-and-the-snapshot-horizon)). Placing
  the cursor "just before the oldest matching event" would skip in-window
  events whose transaction id sorts earlier, because transaction order is not
  time order.
- **Everything the audit log holds**: the cursor is set to `(0, 0)` with no
  `not_before`.
- **A Datadog destination** offers only **From now** and **From the last 17
  hours** ([§5.2](#52-datadog-logs-intake)).

A catch-up is paced: a destination catching up sends at most one batch every
2 seconds, so a large Organization's history does not flood the tool or
crowd out other Organizations' live events. A destination counts as catching
up while its oldest waiting event is more than 10 minutes old.

### 8.6 Retention and a destination that falls behind

The daily retention job (`Kanban.Retention.PurgeWorker`) deletes an
Organization's audit events older than its retention period, through
`Kanban.AuditLog.purge_organization_before/3`. The period can be no shorter
than 90 days. An Organization with no retention period keeps every event, and
its destinations never lose any this way.

**When events are lost.** An event is lost to a destination when it is deleted
or, for Datadog, too old to send ([§5.2](#52-datadog-logs-intake)) before the
destination has received it. For retention, the events a destination is about
to lose are those **after its cursor**, in `(txid, id)` order, whose
`inserted_at` is before the cutoff, leaving out the actions it excludes. Any
destination can lose events this way, whatever its state:

- one that has been failing or halted for longer than the retention period
  (for Datadog, 17 hours);
- one that has been **paused** that long;
- a new destination still catching up on "everything" when the oldest events
  reach the cutoff.

Retention is not held back for a destination: an Organization's retention
promise matters more. Instead, for each Organization with destinations, the
purge step works in this order:

1. **Take the lease** of each of the Organization's destinations, waiting up to
   30 seconds. If a lease can't be taken, this Organization's audit purge is
   skipped for the day and retried the next night. The run records that it
   skipped it.
2. **Count**, for each destination, the events it is about to lose, and their
   first and last times.
3. **Purge**, batch by batch, as today.
4. **Record the loss.** Count again; the events actually lost are the first
   count less the events still present, which is 0 when the purge was refused
   or failed. For a destination that lost events:
   - write a gap in `audit_stream_gaps` ([§9.6](#96-audit_stream_gaps));
   - if a pending batch lost events, discard it ([§8.3](#83-at-least-once-and-batch-identity)).
5. **Release** the leases.

Any error in these steps is caught inside the run's existing per-step
handling, so it can never stop the job's other steps.

**What org-admins see.**

- **A new gap**: the destination page shows it, with its dates, its reason
  and the number of events, until an org-admin dismisses it. Every org-admin
  is emailed, and an `audit_stream_gap` audit event is recorded.
- **An ongoing loss**: while a gap is open (not dismissed), each later loss
  for the same destination and reason extends it, adding to its count and
  widening its dates. It sends a new email at most once every 7 days, and
  records a new `audit_stream_gap` event at most once a day, so an ongoing loss
  does not flood anyone.
- **In the destination itself**: the gap event cannot be excluded
  ([§12.3](#123-abuse-by-an-org-admin)). It reaches the destination when the
  destination reaches it in commit order, which is after the events older
  than it.

The operator function `Kanban.AuditLog.purge_before/1`, which has no caller in
the app, removes rows for every Organization and records no gaps. The new
documentation says not to use it while any destination exists.

### 8.7 Attempts history

Every send records an attempt: time, duration, event count, uncompressed
bytes, first and last event id, HTTP status, outcome and a short error. The
error is at most 200 characters, taken from Stride's own classification and
never from the response body, which can echo secrets or carry markup. A
Splunk `code` and `invalid-event-number` are numbers Stride reads, so the
error may name them. Attempts are kept for 7 days, and at most the newest 200
per destination; the cron job `AuditStream.AttemptPruneWorker` prunes the rest
every hour. Gaps are not attempts, so pruning never removes one.

### 8.8 After a database move

Transaction ids belong to one Postgres server. A physical replica or a Fly
Managed Postgres failover keeps them. A **logical** move does not: dump and
restore, logical replication, or a major-version upgrade done by dump. After
one, new rows get transaction ids lower than the ones already stored and
already in every cursor. The reader would then find nothing after any cursor,
forever, and no delivery would fail.

- **Detection.** Before each read, the worker compares
  `pg_current_xact_id()` with the cursor's `last_txid`. If the database's id
  is lower, transaction ids have gone backwards. The destination is then marked
  **Failing** with `halted_reason` `txid_reset` and the reason "The database
  was moved. An operator must re-seed audit streaming", and every org-admin is
  emailed.
- **Repair.** `Kanban.Release.reseed_audit_stream_cursors/0`, run from a
  release console, sets each cursor to `(0, 0)` with `not_before` set to its
  `last_inserted_at`. It clears any pending batch and `txid_reset`, and records
  an `audit_stream_cursors_reseeded` event for each Organization. Each
  destination then receives every event inserted since the last one it
  received, whatever its `txid`. Events at that exact time may arrive twice,
  and receivers drop them by `id`.
- **Order after a move.** New rows sort before restored ones, because their
  transaction ids are lower. Delivery is in that order, so it is not time
  order across the move, but nothing is skipped.

The operator runbook lists the re-seed as a step of any logical move.

---

## 9. Data model

### 9.1 A commit-order column on `audit_events`

Two migrations. The first adds the column:

```sql
SET LOCAL lock_timeout = '10s';
ALTER TABLE audit_events ADD COLUMN txid bigint NOT NULL DEFAULT 0;
ALTER TABLE audit_events ALTER COLUMN txid
  SET DEFAULT (pg_current_xact_id()::text::bigint);
```

The second, with `@disable_ddl_transaction true` and
`@disable_migration_lock true` (as in `20260709103500_add_tasks_updated_at_index.exs`),
builds the index:

```sql
CREATE INDEX CONCURRENTLY audit_events_org_txid_id_index
  ON audit_events (organization_id, txid, id);
```

- **Existing rows.** Adding the column with a constant default does not
  rewrite the table, and existing rows read as `0`. They are **not** updated,
  because the append-only trigger rejects updates, and nothing needs them to
  be.
- **New rows.** Setting the default afterwards gives every new row its
  transaction's id. `Kanban.AuditLog.AuditEvent` does not cast or set `txid`,
  so application code never sets it. The database does not enforce that: the
  app role's `INSERT` covers every column, so a compromised app role could set
  a `txid` that hides a row from streaming. It could equally not insert the
  row at all. Enforcing it would mean changing the append-only trigger and
  re-hardening, which this item does not do (D10).
- **Range.** `xid8` values are 64-bit and never wrap within one database
  server, so `bigint` holds them ([§8.8](#88-after-a-database-move) covers
  moving the database).
- **Locks.** `lock_timeout` stops the `ALTER`s, which take an `ACCESS
  EXCLUSIVE` lock, from queueing behind a long transaction and holding up
  every audit insert behind them. A `lock_not_available` failure means: run it
  again when the long transaction has ended.
- **The index.** `CREATE INDEX CONCURRENTLY` also waits for transactions open
  when it starts. A failed build leaves an `INVALID` index; drop it with `DROP
  INDEX CONCURRENTLY IF EXISTS audit_events_org_txid_id_index` before retrying.
- **Site events.** Rows without an Organization also get a `txid`. It costs 8
  bytes a row and keeps the table uniform.

**Which database role runs it.** That depends on the database's mode
([audit-log-database-roles.md](../audit-log-database-roles.md)):

- **Degraded: Fly Managed Postgres, which is production today.** Managed
  Postgres has no superuser, so the database cannot be hardened, and the app
  role owns `audit_events`. Both migrations run through the deploy's
  `release_command`, as usual. `Kanban.Release.harden_audit_log/0` returns
  `{:error, :admin_not_superuser}` there, as it already does.
- **Hardened: a self-hosted database where `harden_audit_log` succeeded.** The
  app role cannot alter `audit_events`, so the deploy's `release_command`
  fails on the first migration with `insufficient_privilege`, and the deploy
  stops. The operator then applies the migrations with the table owner's
  rights:
  1. from a one-off machine of the new image, run them with the admin URL as
     `DATABASE_URL` for that one command. Do not use `SET ROLE`: Ecto writes
     `schema_migrations` on the same connection, and the owner role has no
     rights there;
  2. redeploy;
  3. run `Kanban.Release.harden_audit_log()` and then
     `Kanban.Release.audit_log_status()`, expecting `:hardened`. The new
     default calls only `pg_catalog` functions and the index calls none, so the
     status checks are unchanged.

  A1 adds this procedure to the roles doc as a worked example. It is rehearsed
  on a local database hardened with `harden_audit_log`, because a review app
  runs on Managed Postgres and cannot be hardened.

### 9.2 `audit_stream_destinations`

| Column | Type | Notes |
| --- | --- | --- |
| `id` | bigserial | |
| `organization_id` | FK organizations, `on_delete: :delete_all` | |
| `kind` | string | `splunk_hec`, `datadog`, `https` |
| `name` | string, ≤ 80 | Chosen by the org-admin; unique per Organization |
| `enabled` | boolean | `false` while paused by an org-admin |
| `url` | `EncryptedBinary` | Splunk and HTTPS. Null for Datadog |
| `url_host` | string | The host only, for display and audit metadata |
| `url_hint` | string, 4 | The URL's last 4 characters, for HTTPS URLs that carry a token |
| `settings` | map | Non-secret settings by type: Datadog site, service and tags; Splunk index and source type; HTTPS format and header name |
| `credential` | `EncryptedBinary` | HEC token, Datadog API key or header value |
| `credential_hint` | string, 4 | Last 4 characters, for display |
| `signing_secret` | `EncryptedBinary` | HTTPS only |
| `previous_signing_secret` | `EncryptedBinary` | During a rotation |
| `previous_secret_expires_at` | utc_datetime | |
| `include_personal_data` | boolean, default true | [§6](#6-the-event-payload) |
| `excluded_actions` | `{:array, :string}` | Validated against the audit catalog. The `audit_stream_*` actions are refused ([§12.3](#123-abuse-by-an-org-admin)). Applied when a batch is cut, so a change also affects events already waiting |
| `schema_version` | integer, default 1 | |
| `state` | string | `healthy`, `retrying`, `failing` |
| `state_reason` | string | Short, from Stride's own classification |
| `halted_reason` | string, nullable | `rejected_batch`, `blocked_address` or `txid_reset`: the destination waits for a person ([§8.4](#84-retries-and-failure)) |
| `failing_since` | utc_datetime | |
| `consecutive_failures` | integer | |
| `last_success_at` | utc_datetime | |
| `failing_emailed_at`, `recovered_emailed_at` | utc_datetime | For the at-most-once-an-hour rule |
| `created_by_id` | FK users, `nilify_all` | For the record only |
| `lock_version` | integer | Optimistic locking for concurrent edits |
| timestamps | | |

### 9.3 `audit_stream_cursors`

Kept apart from the destination so the worker's frequent updates never
conflict with an org-admin editing the settings.

| Column | Type | Notes |
| --- | --- | --- |
| `destination_id` | PK, FK, `on_delete: :delete_all` | |
| `last_txid`, `last_event_id` | bigint | The position after which events are read. `(h, 0)` for a destination that starts from now and `(0, 0)` for one that catches up, until its first delivery ([§8.5](#85-starting-point-and-catch-up)) |
| `last_inserted_at` | utc_datetime_usec, nullable | The `inserted_at` of the last event delivered, for re-seeding ([§8.8](#88-after-a-database-move)) |
| `not_before` | utc_datetime_usec, nullable | For a time-window start ([§8.5](#85-starting-point-and-catch-up)) |
| `pending_batch_id` | uuid | [§8.3](#83-at-least-once-and-batch-identity) |
| `pending_first_txid`, `pending_first_id`, `pending_last_txid`, `pending_last_id` | bigint | The pending batch's range |
| `pending_attempts` | integer | |
| `next_attempt_at` | utc_datetime_usec, nullable | When the destination is next due ([§8.4](#84-retries-and-failure)) |
| `lease_token` | uuid, nullable | The run holding the lease ([§8.1](#81-workers-and-scheduling)) |
| `leased_until` | utc_datetime_usec, nullable | |
| `updated_at` | utc_datetime_usec | |

### 9.4 `audit_stream_attempts`

| Column | Type |
| --- | --- |
| `id` | bigserial |
| `destination_id` | FK, `on_delete: :delete_all` |
| `batch_id` | uuid |
| `started_at` | utc_datetime_usec |
| `duration_ms` | integer |
| `event_count`, `bytes` | integer |
| `first_event_id`, `last_event_id` | bigint |
| `http_status` | integer, nullable |
| `outcome` | string: `delivered`, `retry`, `rejected`, `unauthorized`, `config_error`, `blocked`, `skipped` |
| `error` | string, ≤ 200 |

Index `[destination_id, started_at]`.

### 9.5 Contexts and modules

| Module | Purpose |
| --- | --- |
| `Kanban.AuditStream` | The context: destinations (create, update, pause, resume, delete, rotate secret, send test), status and lag, attempts, gaps (list, dismiss), and the Scheduler's "due with events waiting" query. Every function takes the scope first and checks org-admin |
| `Kanban.AuditStream.Destination`, `Cursor`, `Attempt`, `Gap` | Schemas and changesets |
| `Kanban.AuditStream.Reader` | The query in [§7.2](#72-the-approach-transaction-ids-and-the-snapshot-horizon), with the `:horizon` option, redaction, personal data and filtering |
| `Kanban.AuditStream.Payload` | [§6](#6-the-event-payload) |
| `Kanban.AuditStream.Adapter` and `Adapters.SplunkHec`, `Adapters.Datadog`, `Adapters.Https` | [§5](#5-destinations) |
| `Kanban.AuditStream.DispatchWorker`, `Scheduler`, `AttemptPruneWorker` | [§8](#8-delivery) |
| `Kanban.AuditStream.Retention` | The gap steps that `Retention.PurgeWorker` calls ([§8.6](#86-retention-and-a-destination-that-falls-behind)) |
| `Kanban.Release.reseed_audit_stream_cursors/0` | [§8.8](#88-after-a-database-move) |
| `Kanban.AuditLog.Signing` | [§11](#11-signed-audit-exports) |

`Kanban.AuditStream` is a new context rather than part of `Kanban.AuditLog`,
which is already large and has one job: recording and reading events.

### 9.6 `audit_stream_gaps`

| Column | Type | Notes |
| --- | --- | --- |
| `id` | bigserial | |
| `destination_id` | FK, `on_delete: :delete_all` | |
| `reason` | string | `retention` or `too_old` (Datadog) |
| `events` | integer | Events lost, added to while the gap is open |
| `first_occurred_at`, `last_occurred_at` | utc_datetime_usec | The dates of the lost events |
| `opened_at`, `last_extended_at` | utc_datetime_usec | |
| `emailed_at`, `audited_at` | utc_datetime_usec | For the throttles in [§8.6](#86-retention-and-a-destination-that-falls-behind) |
| `dismissed_at` | utc_datetime_usec, nullable | |
| `dismissed_by_id` | FK users, `nilify_all` | |

Index `[destination_id, dismissed_at]`. Gaps are kept until the destination is
deleted.

---

## 10. Screens

All text is translated into every language Stride supports: de, en, es, fr,
ja, pt and zh. Every screen works in light and dark mode, using the tokens in
the [dark mode contract](../dark-mode-contract.md).

### 10.1 Where it lives

A new page, **Audit streaming**, at `/org/audit/streaming`
(`KanbanWeb.OrgLive.AuditStreaming`), in the existing
`live_session :require_authenticated_user` block next to `/org/audit`. It is
reached from a **Streaming** button in the header of the Organization audit
log page, beside **Export CSV** and **Export JSON**, and from the Organization
console's header buttons.

### 10.2 The destination list

Each destination shows as a row:

- its name and type (Splunk, Datadog, HTTPS endpoint), its host, and the last
  4 characters of its credential or URL;
- a status pill: **Healthy**, **Retrying**, **Failing** or **Paused**,
  with the reason for the last two, and **Needs attention** when it is halted;
- **Last delivered**: how long ago, and the time in UTC;
- **Behind by**: the number of events waiting and the age of the oldest, or
  **Up to date**. Events held above the horizon count as waiting
  ([§13.1](#131-telemetry)), so a held horizon never shows as up to date;
- **Pause**/**Resume**, **Edit**, **Send test event** and **Delete**.

A note above the list states the limit: "An Organization can have up to 3
destinations." **Add destination** is disabled at the limit, and says why.
When the Organization has only one enabled org-admin, a second note says that
the change emails go only to that person, and suggests adding another
org-admin ([§12.3](#123-abuse-by-an-org-admin)).

When a destination has an open gap ([§8.6](#86-retention-and-a-destination-that-falls-behind)),
its row shows a warning with the number of events lost and their dates, until
an org-admin dismisses it.

### 10.3 Adding or editing a destination

A form, using the core `<.input>` and `<.button>` components:

1. **Type**: Splunk, Datadog or HTTPS endpoint. The fields below change with
   it ([§5](#5-destinations)).
2. **Name**.
3. The type's settings. Secret fields are write-only: an existing value shows
   as "•••• 1a2b" with **Replace**, and is never sent back to the browser.
4. **Start from**: now, last 24 hours, last 7 days or everything the audit log
   holds. For Datadog, now or the last 17 hours. Shown only when creating, and
   a catch-up choice says that every org-admin will be told about it.
5. **Include email and IP addresses**, on by default, with a line explaining
   what turning it off removes.
6. **Leave out these actions**: a multi-select of the actions, with their
   labels. The `audit_stream_*` actions are not offered.

**Save** validates the settings, checks the URL with `UrlGuard`, and then
sends a test event. The test event is synthetic: it has the `stride.audit.v1`
shape and the action `audit_stream_test_sent`, and carries no real audit
data. The destination is saved even if the test fails. The result is shown as
"Test event delivered" or a coarse class: "Could not connect" (covering a
refused connection, a timeout and a host that does not resolve), "The
certificate could not be verified", "The destination refused the
credentials" or "The destination answered with an error (*status*)". The
coarse class stops the test from telling an org-admin which ports are open on
another host ([§12.5](#125-load-and-fairness)). For an HTTPS destination, the
signing secret is shown once, after the first save, with a **Copy** button and
the warning that it will not be shown again.

### 10.4 The destination's page

`/org/audit/streaming/:id` shows:

- the settings;
- the status in full, with the reason when it is halted;
- the lag;
- its open and dismissed gaps, with **Dismiss** on an open one;
- the last 50 attempts as a table (time, events, size, status, outcome,
  error).

For HTTPS destinations it has **Rotate signing secret**, which keeps the old
secret valid for 24 hours and shows the new one once.

When a batch has been rejected ([§8.4](#84-retries-and-failure)), the page
shows the destination's answer as Stride classified it, the number of events
in the batch and their first and last times, and two buttons:

- **Retry now**, for when the cause has been fixed at the tool's end;
- **Skip this batch**, which asks for confirmation ("These N events will not
  be sent to this destination. They stay in the audit log and in exports.")
  and then carries on with the next batch.

For a Splunk 400 that named an `invalid-event-number`, the page adds that the
events before that one may already be in Splunk. A configuration error shows
its fix and no **Skip this batch** ([§5.1](#51-splunk-http-event-collector)).

### 10.5 Confirmations

Deleting a destination, pausing it, and turning off personal data each ask
for confirmation. Deleting says that events will no longer be sent and that
the history of attempts and gaps goes too. Deleting does not delete anything
already in the destination tool.

---

## 11. Signed audit exports

### 11.1 Why

An audit export is evidence, for an auditor, a customer or a court. Today
nothing shows that a CSV file has not been edited since Stride produced it. A
signed export lets anyone check that, without trusting the person who hands
the file over and without access to Stride.

### 11.2 What a signed export is

**Export signed (.zip)** on the Organization audit log page downloads one zip
holding:

| File | Contents |
| --- | --- |
| `audit_log.csv` or `audit_log.json` | Exactly the file an unsigned export produces |
| `manifest.json` | What the export is ([§11.3](#113-the-manifest)) |
| `manifest.json.sig` | The Ed25519 signature over the bytes of `manifest.json`, raw 64 bytes |
| `README.txt` | How to verify, in three commands, with the `openssl` and `shasum` commands, and where to find the Python alternative |

Erlang's `:zip` cannot write to a streaming response. So the export is written
to a temporary file first, as the workspace export does
(`lib/kanban/workspaces/export/writer.ex`), and the zip is built from it and
sent. The temporary file is deleted when the response ends or fails. Memory
stays bounded at the 50,000-row cap.

The plain **Export CSV** and **Export JSON** stay as they are. A signed export
counts towards the same rate limit (10 an hour per org-admin) and the same
50,000-row cap. It records the same `org_audit_log_exported` audit event, with
`signed: true`, the `key_id` and the file's `sha256` in its metadata, so the
audit log shows which signed file was issued.

### 11.3 The manifest

```json
{
  "schema": "stride.audit-export.v1",
  "instance": "stridelikeaboss.com",
  "organization": {"id": 210, "name": "Northwind Studio"},
  "generated_at": "2026-11-09T15:20:04Z",
  "generated_by": {"user_id": 1153, "email": "alex@northwind.example"},
  "filters": {"action": null, "from": "2026-10-01", "to": "2026-10-31"},
  "file": {"name": "audit_log.csv", "format": "csv", "bytes": 482113,
           "sha256": "9f2c…"},
  "rows": 1834,
  "oldest_event": {"id": 1720044, "inserted_at": "2026-10-01T00:03:12Z"},
  "newest_event": {"id": 1849230, "inserted_at": "2026-10-31T23:58:40Z"},
  "truncated": false,
  "key_id": "k1-3f9a1c0d2e4b5a67"
}
```

- **Field names follow the file.** `inserted_at` and integer `id`s, as in the
  export's columns. The file lists events newest first, so `newest_event` is
  its first row and `oldest_event` its last.
- **`truncated` is decided while streaming.** The export reads one row past
  the cap. `truncated` is `true` only when that extra row exists, and the
  extra row is not written. It can differ from the pre-count in the
  `org_audit_log_exported` event, which is taken before streaming. The signed
  zip does not send the `x-export-truncated` header; the manifest is the
  record.
- **One read.** The file's SHA-256 is computed while it is written, so
  producing a signed export reads the events only once. The manifest is
  written last, signed, and added to the zip.

### 11.4 Keys

- **One signing key per Stride instance**, an Ed25519 key pair. Ed25519 is in
  Erlang's `:crypto` (`:crypto.sign(:eddsa, :none, msg, [priv, :ed25519])`),
  so no dependency is added. The same key signs export manifests and the
  `X-Stride-Audit-Signature` on streamed HTTPS batches
  ([§5.3](#53-any-https-endpoint)), so a receiver and an auditor check
  against the same published key.
- **Configuration.** `config/runtime.exs` reads three variables. A value that
  is set but does not parse stops the boot, naming the variable and never
  printing it.

  | Variable | Format |
  | --- | --- |
  | `AUDIT_SIGNING_KEY` | The private key, as PEM or as base64 of the 32-byte seed |
  | `AUDIT_SIGNING_KEYS_PREVIOUS` | Retired public keys, comma-separated, each as base64url of the 32 raw public-key bytes |
  | `AUDIT_SIGNING_KEYS_REVOKED` | Revoked public keys, in the same format |

  - **Not set in production:** signed exports are turned off, streamed
    batches carry the HMAC only, and the boot logs a warning, as attachments do
    for local storage. The export button then says "Signed exports are not set
    up on this server."
  - **Not set in development:** a key is generated once and kept in
    `tmp/audit_signing_key.pem`, which git ignores, so exports and stored batch
    signatures still verify after a restart.
  - **In tests:** each run generates its own key.
- **Key id and fingerprint.** Both are computed over the **32 raw public-key
  bytes**, the JWK `x` value after base64url decoding:
  - the key id is `k1-` followed by the first 16 lowercase hex characters of
    their SHA-256;
  - the fingerprint is the full 64-character SHA-256.

  The doc gives a one-line `openssl` command that reproduces both from the
  PEM.
- **Publishing.** `GET /.well-known/stride-audit-signing-keys` is served by a
  new `KanbanWeb.AuditSigningKeysController`, in a new
  `scope "/.well-known", KanbanWeb` with no browser session pipeline.
  - **Default:** a JSON Web Key Set (`"kty":"OKP","crv":"Ed25519"`, `kid` as
    above) of the current key and the previous ones, plus a `revoked` list of
    each revoked key's `kid` and the date it was revoked.
  - **`?format=pem&kid=<key id>`:** exactly one key as PEM, or 404 for a key
    that is unknown or revoked.

  It is public, needs no sign-in, and is sent with `Cache-Control: public,
  max-age=3600`. The Organization audit log page shows the current key id and
  fingerprint and links to it, so an auditor can record the fingerprint
  independently.
- **Rotation.** Retired keys stay published, so old exports and stored batch
  signatures still verify. The operator runbook gives the steps:
  1. generate a key with `openssl genpkey -algorithm ed25519`;
  2. add the current public key to `AUDIT_SIGNING_KEYS_PREVIOUS`;
  3. set the new private key;
  4. deploy.
- **Revocation** is a different step, for a key that has leaked
  ([§17](#17-risks)). The key moves to `AUDIT_SIGNING_KEYS_REVOKED`, never to
  the previous list, and so leaves the published set. Exports and stored batch
  signatures made with it no longer prove anything: the runbook says to
  re-export, and to tell receivers that kept the key's `kid`.

### 11.5 Verifying

The README in each zip, and the new doc, give these commands. They need
**OpenSSL 3.0 or later**: check with `openssl version`. The `openssl` that
ships with macOS is LibreSSL, which cannot check Ed25519 signatures. On a Mac,
install OpenSSL 3 (for example `brew install openssl@3`) and run it by its full
path.

```sh
# 1. Get the public key named by key_id in manifest.json (or use the one you recorded earlier)
curl -fsS "https://<stride host>/.well-known/stride-audit-signing-keys?format=pem&kid=<key_id>" -o stride-audit.pem
# 2. Check the signature on the manifest
openssl pkeyutl -verify -pubin -inkey stride-audit.pem -rawin -in manifest.json -sigfile manifest.json.sig
# 3. Check the file against the manifest (or: openssl dgst -sha256, or sha256sum)
shasum -a 256 audit_log.csv     # must equal file.sha256 in manifest.json
```

The URL is quoted because the default macOS shell, zsh, would otherwise treat
`?` as a wildcard. The doc also gives a short Python example with the
`cryptography` package, which works anywhere, for people who want to automate
the check.

### 11.6 What a signature proves, and what it does not

It proves that **this Stride instance produced these exact bytes** at the
stated time, for the stated Organization and filters, as long as the key has
not been revoked. It does not prove the export is complete beyond what the
manifest says: a filtered or truncated export says so in `filters` and
`truncated`. Nor does it prove anything about events the database held before
they were exported; that is the job of the append-only table and its
hardening.

### 11.7 Later: a hash chain over the stored log

Outside this item, but designed to fit: each stored row would carry
`chain_hash = sha256(previous chain_hash ‖ canonical row)`, computed in commit
order by the same `txid` ordering as [§7](#7-reading-events-in-commit-order).
The manifest would then carry the chain hash of its last row, and streamed
events could carry theirs. Because streamed batches are already signed with
Ed25519 ([§5.3](#53-any-https-endpoint)), a destination could then prove both
where the events came from and that nothing was removed between two of them.
It needs its own design, because computing the chain in commit order means a
background job, not the insert. It also has to handle a logical database
move, after which `txid` order restarts ([§8.8](#88-after-a-database-move)).

---

## 12. Security

### 12.1 Sending to the internet safely

Every request goes through `Kanban.Webhooks.UrlGuard` and
`Kanban.Webhooks.Transport`, unchanged:

- HTTPS only in production, with certificate verification and no way to turn
  it off;
- every resolved address checked, private, loopback, link-local and reserved
  ranges refused, IPv4 embedded in IPv6 checked too, and the connection pinned
  to the approved address so a DNS change cannot point it elsewhere;
- no redirects, 5 s to connect, 10 s to answer, response body read up to
  64 KB and never stored.

Datadog URLs are built from a fixed list of sites, and Splunk and HTTPS URLs
are checked when they are saved and again before every send.

Stride sends from addresses that can change, and does not publish a list of
them (D14). A collector that only accepts listed addresses, such as a Splunk
Cloud stack whose HEC allow list has been narrowed, will refuse the
connection. The destination then shows **Failing** with "Could not connect",
and the doc says such collectors are not supported. Datadog's intake is not
subject to an account's IP allow list.

### 12.2 Secrets

- URLs (for HTTPS and Splunk), tokens, API keys, header values and signing
  secrets are encrypted with `Kanban.Encryption` (AES-256-GCM, `ENCRYPTION_KEY`).
  Losing `ENCRYPTION_KEY` makes them unreadable; destinations then show
  **Failing** with "Credentials can't be read. Enter them again."
- Secrets are write-only in the UI and never logged, put in telemetry, put in
  audit metadata or shown in errors. Audit metadata names a destination by its
  id, type, name and host only, and only the id, type and outcome reach
  telemetry ([§13.2](#132-new-audit-actions)).
- The production signing private key lives only in the environment. It is
  never stored in the database or written to disk by Stride, and operators
  must keep it out of logs and crash dumps. Only the development key is kept
  on disk ([§11.4](#114-keys)).

### 12.3 Abuse by an org-admin

A destination sends the Organization's security events, emails and IP
addresses to a place outside Stride. A compromised or malicious org-admin
account could use it to send them somewhere it should not, to hide events from
the Organization's existing SIEM, or both. The design limits and exposes that:

- only org-admins can create or change destinations, and the Organization's
  two-factor requirement applies;
- every change is an audit event, which the existing destinations also
  receive. They cannot be told to leave those events out, because the
  `audit_stream_*` actions cannot be excluded;
- **every org-admin is emailed**, with who did it and the destination's name,
  host and credential hint, when a destination is:
  - created, with its start point;
  - deleted, paused or resumed;
  - changed in its URL, credential, personal-data setting, excluded actions,
    or any other setting that decides where its events go: the Splunk index,
    Datadog site, service or tags, or the HTTPS header name;
- **a catch-up is named as one.** A creation that starts from 24 hours, 7 days
  or everything says so in the email's subject, because sending the whole
  history out is the most damaging form of this abuse;
- a new destination starts **from now** unless the org-admin chooses
  otherwise, and the catch-up choice is in the audit event;
- **the hint tells tenants apart.** Many tools share one collector host
  (Datadog, Sumo Logic, Google Security Operations), so the host alone says
  little about where the data goes. The emails and the page therefore show the
  credential's or URL's last 4 characters too.

What this cannot do:

- **One org-admin.** In an Organization with only one enabled org-admin, the
  emails go only to that person, who may be the attacker. The same is true
  after an attacker removes the other org-admins, for example through SCIM,
  although each removal is itself an audit event that the existing
  destinations receive. The destination list warns when there is only one
  org-admin ([§10.2](#102-the-destination-list)).
- **Forced rejections.** An org-admin could make the legitimate SIEM reject
  batches, for example by setting a Splunk index the token cannot write to.
  That is now a configuration error with no **Skip this batch**
  ([§5.1](#51-splunk-http-event-collector)), and the index change itself is
  emailed.
- **Retention.** Lowering the Organization's retention to the 90-day floor
  while pausing its SIEM turns into a gap after 90 days. The pause is emailed
  at once, before anything is lost.

### 12.4 What is never sent

Streaming sends what the audit log stores. `Kanban.AuditLog.event/2` already
drops metadata keys whose names contain `password`, `token`, `secret`,
`authorization`, `key` or `otp`, caps every value, and replaces NUL. Streaming
adds the outside-actor redaction and the optional removal of email and IP
addresses, from both the top level and `metadata`
([§6](#6-the-event-payload)). It never adds anything the Organization audit
page does not show.

### 12.5 Load and fairness

- At most 3 destinations an Organization and 5 concurrent sends on each node,
  on a queue of their own, so streaming cannot delay notifications,
  webhooks or exports.
- Catch-up is paced ([§8.5](#85-starting-point-and-catch-up)).
- **Test events**, from **Send test event** and from every **Save**, are limited
  to 10 an hour **per Organization**, so deleting and re-creating a
  destination does not reset the limit. Each one is an `audit_stream_test_sent`
  audit event, and its result is shown only as a coarse class
  ([§10.3](#103-adding-or-editing-a-destination)), so the test cannot be used
  to probe another host's ports.

---

## 13. Telemetry, audit events, notifications and docs

### 13.1 Telemetry

Declared in `Kanban.Telemetry.Catalog`, in a new `AuditStreamEvents` module,
emitted with `Kanban.Telemetry.emit/3`, and tested with
`Kanban.TelemetryHelpers.attach_telemetry/2`. Each event is declared in the
task that first emits it, which also refreshes the event reference in
`docs/telemetry.md` ([§16](#16-goals-tasks-and-order)).

| Event | Measurements | Metadata | Metric |
| --- | --- | --- | --- |
| `[:kanban, :audit_stream, :batch_delivered]` | `count`, `events`, `bytes`, `duration_ms` | `kind` | counter, sum of events, summary of duration, tagged by `kind` |
| `[:kanban, :audit_stream, :batch_failed]` | `count`, `duration_ms` | `kind`, `outcome` | counter tagged by `kind` and `outcome` |
| `[:kanban, :audit_stream, :lag_measured]` | `lag_seconds`, `events_waiting`, `events_above_horizon` | `kind` | summary of `lag_seconds` tagged by `kind`, persisted, so a growing lag shows in the metrics history |
| `[:kanban, :audit_stream, :gap_recorded]` | `count`, `events` | `kind`, `reason` | counter |

- **The lag measurements:**
  - `events_waiting` counts the rows after the cursor with no horizon filter;
  - `lag_seconds` is the age of the oldest of them;
  - `events_above_horizon` counts those not yet below the horizon.

  A held horizon therefore shows as waiting events and a growing lag, never as
  zero ([§7.3](#73-what-it-costs)).
- **Emission:** `lag_measured` is emitted by the sweep at most once every 15
  minutes per destination. That keeps it rare enough to persist, under the
  rule in [telemetry.md](../telemetry.md), whose list of stored events gains
  it.
- **What metadata carries:** no Organization id, URL, host, destination name
  or email address.

### 13.2 New audit actions

Added to `@audit_actions` in `Kanban.Telemetry.Catalog.Families`, with labels
in `KanbanWeb.AuditLogActions` translated into every locale. The keys declared
in `@audit_actions` are what reach telemetry. The stored row can carry more:
its metadata holds every key the caller passes, after sanitising.

| Action | Telemetry keys (declared) | Also stored in the row |
| --- | --- | --- |
| `audit_stream_destination_created` | `destination_id`, `kind`, `start_from`, `include_personal_data` | `name`, `url_host` |
| `audit_stream_destination_updated` | `destination_id`, `kind` | `changed` (field names only), `name`, `url_host` |
| `audit_stream_destination_paused`, `_resumed`, `_deleted` | `destination_id`, `kind` | `name` |
| `audit_stream_signing_secret_rotated` | `destination_id` | |
| `audit_stream_batch_skipped` | `destination_id`, `kind`, `events`, `http_status` | `first_event_id`, `last_event_id` |
| `audit_stream_test_sent` | `destination_id`, `outcome` | |
| `audit_stream_failing`, `audit_stream_recovered` | `destination_id`, `kind`, `reason` (no actor: recorded by the system) | |
| `audit_stream_gap` | `destination_id`, `events`, `reason` | `from`, `to` |
| `audit_stream_gap_dismissed` | `destination_id` | `gap_id` |
| `audit_stream_cursors_reseeded` | `destinations` (no actor: recorded by an operator's release command) | |

Every action also carries `user_id` and `organization_id`, as every
Organization audit action already does. `org_audit_log_exported` gains
`signed` in its declared keys, and `key_id` and `sha256` in its stored
metadata. C3 adds `:signed` to its entry in `families.ex`, or telemetry would
drop the key.

### 13.3 Emails

Sent to every enabled org-admin of the Organization through
`Kanban.Notifications`, each in the recipient's own locale, as the
announcement worker sends them. These are security emails: they ignore
notification preferences and have no unsubscribe link, as other security
emails do. They are sent when:

- a destination is created (with its start point; a catch-up is named in the
  subject), deleted, paused or resumed, or has a setting changed that decides
  where its events go, which personal data it carries, or which actions it
  leaves out ([§12.3](#123-abuse-by-an-org-admin)). Each says by whom, which
  destination, its host and its credential hint;
- a destination became Failing, and later recovered (at most once an hour
  each);
- a gap was opened, and while it grows, at most once every 7 days
  ([§8.6](#86-retention-and-a-destination-that-falls-behind));
- transaction ids went backwards and an operator must re-seed
  ([§8.8](#88-after-a-database-move)).

### 13.4 Docs

- **New:** `docs/audit-log-streaming.md`, for org-admins and operators:
  - setting up each destination type, with Splunk's collector host forms and
    the indexer-acknowledgement rule, and Datadog's 17-hour limit;
  - the payload;
  - verifying an HTTPS delivery by its HMAC or its Ed25519 signature, with a
    Python and a Node example of each, including inflating the body and the
    unpadded base64url;
  - lag, a held horizon and where to look;
  - failures, gaps and limits;
  - the operator settings: `AUDIT_STREAM_MAX_DESTINATIONS`, Fly's
    `min_machines_running`, and the re-seed after a database move.

  It is added to the index in `docs/README.md` and links to the signed-exports
  doc for verifying exports.
- **New:** `docs/audit-log-signed-exports.md`, for auditors and operators:
  - verifying a signed export with OpenSSL 3 and with Python;
  - the key endpoint, key id and fingerprint;
  - the operator's runbook for rotating and for revoking a key, and the three
    `AUDIT_SIGNING_*` variables.

  It is added to the index in `docs/README.md`.
- `docs/organizations.md`, *The Organization audit log*: streaming and signed
  exports, with links.
- `docs/audit-log-database-roles.md`: the `txid` migrations as a worked example
  of a migration that alters `audit_events`, in both modes, with the follow-up
  `harden_audit_log` and `audit_log_status` checks
  ([§9.1](#91-a-commit-order-column-on-audit_events)).
- `docs/telemetry.md`: the new events and audit actions. Each task that adds a
  catalog entry refreshes the event reference itself. B6 writes the prose.
- An in-app Resources guide, *Streaming your audit log to a security tool*,
  with screenshots in light and dark mode, as its own task.
- `CHANGELOG.md`, `priv/changelog/body.html`, `ROADMAP.md` (move the item to
  Complete), and the Organization plan's feature list on the pricing page,
  translated, as the last task.

---

## 14. Testing strategy

| Area | Tests |
| --- | --- |
| Commit order | In the throwaway race database (`MIX_TEST_PARTITION=_race`, sandbox off), with the real horizon. **The order test must tell `(txid, id)` order from `id` order:** transaction T1 starts and takes a transaction id first (`SELECT pg_current_xact_id()`), then T2 inserts event B, then T1 inserts event A. A has the lower `txid` and the higher `id`. Both commit, in either order, and the reader must return A before B, each once. Then: a long-open writing transaction holds the horizon back, and the reader returns nothing past it; a read-only open transaction does not; a rolled-back event never appears. Repeated with many concurrent writers and a reader looping, checking that the delivered set equals the committed set with no duplicates. Assertions compare events with each other, never with absolute transaction ids, and wait for the horizon to pass the test's own transactions, so another database on the same server only slows the test down |
| Migration | Existing rows read `txid = 0`; new rows get a real transaction id; `AuditEvent` never casts `txid`. Under `AuditLogRoleHelper`, the hardened end state is checked: the owner is unchanged, the app role cannot alter the table, and `audit_log_status` still reports hardened |
| Reader | In the sandbox, with the `:horizon` option set above the test's own transaction: Organization scoping, redaction of outside actors (keys removed from `metadata`), the personal-data switch removing `email` and `ip` keys at every depth, excluded actions, `not_before`, batch size and the byte limit |
| Adapters | Each type's request (URL, headers, gzip body) against `Req.Test` stubs, and each response classified correctly. Splunk: every HEC code in [§5.1](#51-splunk-http-event-collector), including 200 with codes 24 and 25, and the path check. Datadog: the `date` field, the `message` with personal data off, the 17-hour cut-off, the tag limits, and 401 and 408. 413 splitting for each. HTTPS: the HMAC verifies with the webhook verifier on the inflated body, including both values during a rotation; the Ed25519 signature verifies, from the gzip bytes after inflation, against the published key chosen by `kid`, over `t`, the destination id and the body; a changed byte fails both; with no signing key, only the HMAC is sent |
| Worker | With Oban `testing: :disabled` in the race partition, because Oban only applies uniqueness then: one job per destination plus at most one follow-up; the lease stops a second run; a run whose lease expired cannot move the cursor; no transaction is open during the POST. Also: the cursor moves only on 2xx; a retry resends exactly the pending batch; `next_attempt_at` holds the backoff, Retry-After and the cap against the sweep; a halted destination is never swept; draining and catch-up pacing; state moves Healthy → Retrying → Failing → Healthy with the right emails; a `txid` lower than the cursor's halts the destination |
| Retention | A destination behind the cutoff records a gap with the right count, including a paused one; a refused purge records none; a pending batch that loses events is discarded and the next batch has a new `batch_id`; a second loss extends the open gap without a new email; a lease that can't be taken skips the Organization; retention still purges |
| Re-seed | `reseed_audit_stream_cursors/0` sets `(0, 0)` and `not_before`, clears `txid_reset`, and the next batch starts at the last delivered event's time |
| Security | `UrlGuard` refusals at save and send time; secrets never appear in rendered HTML, logs, telemetry or audit metadata; `name` and `url_host` never reach telemetry; a non-org-admin, and an org-admin of another Organization, get nothing; a reserved header name is refused; `audit_stream_*` cannot be excluded; the test-event limit is per Organization and its result is coarse |
| UI | The LiveViews in every supported locale (de, en, es, fr, ja, pt, zh), including plural forms; write-only secret fields, the limit of 3, the one-org-admin warning, gaps and **Dismiss**, confirmations, and light and dark mode |
| Emails | Each email kind in a recipient's locale, the throttles, and the catch-up subject |
| Signed exports | The zip's contents; the manifest's SHA-256 matches the file; `truncated` from the stream; the signature verifies with `:crypto` and with the `openssl` command in the README, in a test tagged to run only where OpenSSL 3 or later is installed; a changed byte fails verification; the key endpoint's JWKS, the single-key PEM by `kid`, 404 for a revoked key, and the cache header; boot refuses a malformed key and warns on a missing one |
| Telemetry | Catalog entries, call sites, and no forbidden keys, by the existing telemetry tests |

Before release, an exploratory session sends real events to these
destinations, stops each one for a while, and checks that nothing is lost or
duplicated beyond what `id` resolves:

- a paid or developer Splunk Cloud stack, or a local Splunk Enterprise with a
  trusted certificate (trial stacks use self-signed certificates);
- a Datadog trial;
- a local HTTPS receiver.

---

## 15. Decisions needed

| # | Question | Decision |
| --- | --- | --- |
| D1 | Production must run Postgres 13 or later for `pg_current_xact_id()`. | **Settled on 2026-11-10:** production runs Postgres 13 or later, and streaming requires it. The reader uses the transaction-id approach in [§7.2](#72-the-approach-transaction-ids-and-the-snapshot-horizon); the time-window fallback in [§7.1](#71-the-problem) is never used |
| D2 | How many destinations can an Organization have? | **Settled on 2026-11-10:** 3 by default. An operator can change it with `AUDIT_STREAM_MAX_DESTINATIONS` ([§5](#5-destinations)) |
| D3 | A batch the destination rejects permanently (a 4xx other than 401, 403, 408, 413 or 429, and not a Splunk configuration code, three times): stop the destination, or skip the batch? | **Settled on 2026-11-10: stop.** The destination is marked Failing, halted, and keeps its cursor, so nothing is lost. An org-admin chooses **Retry now** after fixing the cause, or **Skip this batch**, which records an attempt with outcome `skipped` and an `audit_stream_batch_skipped` audit event ([§8.4](#84-retries-and-failure)). Stride never skips on its own |
| D4 | Should **Include email and IP addresses** default to on? | **Settled on 2026-11-10: on.** The destination is a security tool, and the Organization audit page already shows the same data to the same people. Org-admins can turn it off for each destination ([§6](#6-the-event-payload)) |
| D5 | Should the stream also carry an Ed25519 signature, so a receiver needs no shared secret? | **Settled on 2026-11-10: yes, both.** Batches sent to an HTTPS endpoint carry the HMAC `X-Stride-Signature`, in the webhook format, and an Ed25519 `X-Stride-Audit-Signature` made with the instance's audit signing key ([§5.3](#53-any-https-endpoint), [§11.4](#114-keys)). The Ed25519 signature needs no shared secret and proves the batch came from this instance. Splunk and Datadog batches carry neither, as those tools authenticate with their own tokens |
| D6 | Signing: one key per instance, or one per Organization? | **Settled on 2026-11-10: one per instance.** One Ed25519 key from `AUDIT_SIGNING_KEY` signs both export manifests and streamed HTTPS batches, and is published at one address ([§11.4](#114-keys)). Per-Organization keys would add key storage and rotation in the database for no gain in what the signature proves |
| D7 | Should signed exports be the only kind? | **Settled on 2026-11-10: no.** **Export CSV** and **Export JSON** stay as they are, for people who just want to read the log, and **Export signed (.zip)** is added beside them. All three share the rate limit and the row cap ([§11.2](#112-what-a-signed-export-is)) |
| D8 | Should a site admin be able to see an Organization's destinations? | **Settled on 2026-11-10: no**, as with the rest of the Organization console. Only the Organization's org-admins see its destinations. Support works from the four streaming events in [§13.1](#131-telemetry), which carry no Organization, URL or host ([§4](#4-access-and-the-plan-gate)) |
| D9 | How do new events start a delivery: an after-commit nudge, or only the sweep? | **Settled on 2026-11-10: only the sweep, every minute.** `event/2` has no after-commit point, and adding one would change its contract ([§8.1](#81-workers-and-scheduling)). Latency is within about a minute. A `pg_notify` trigger can be added later |
| D10 | Should the database stop the app from setting `txid`? | **Settled on 2026-11-10: no.** Application code never sets it; enforcing it would mean changing the append-only trigger and re-hardening, and a compromised app role could hide an event just as well by not recording it ([§9.1](#91-a-commit-order-column-on-audit_events)) |
| D11 | How does a Datadog destination handle Datadog dropping entries more than 18 hours old? | **Settled on 2026-11-10:** it starts from now or the last 17 hours, never sends an event older than 17 hours, and records the ones it can't send as a gap ([§5.2](#52-datadog-logs-intake)) |
| D12 | Organizations have no slug. Add one, or identify the Organization another way? | **Settled on 2026-11-10: no slug.** The payload and the manifest carry the Organization's `id` and `name`, and Datadog is tagged `organization_id:<id>` ([§6](#6-the-event-payload)) |
| D13 | What do the batch signatures cover? | **Settled on 2026-11-10:** the decompressed body. The Ed25519 signature also covers the destination id, so a batch can't be passed off as meant for another destination ([§5.3](#53-any-https-endpoint)) |
| D14 | Publish fixed egress addresses for collectors that only accept listed addresses? | **Settled on 2026-11-10: no**, not in this item. Such collectors are not supported, and the doc says so ([§12.1](#121-sending-to-the-internet-safely)) |
| D15 | Production stops its last machine when idle (`min_machines_running = 0`), which stops the sweep. Keep one machine running? | **Settled on 2026-11-10: yes.** B8 sets `min_machines_running = 1` in `fly.production.toml` when streaming ships, at the cost of one always-on machine, so the sweep, retries and Failing alerts never wait for a visitor ([§8.1](#81-workers-and-scheduling)) |

---

## 16. Goals, tasks and order

Three goals. Each task is about 1 to 3 hours.

Every task that adds text visible in the UI runs `mix gettext.extract --merge`
and translates every locale (de, en, es, fr, ja, pt, zh). Every task that
changes a screen passes `mix dark_mode.scan` and `mix dark_mode.contrast
--enforce` and is checked in light and dark mode. The `after_doing` hook does
not run these, so each such task lists them in its verification steps. Every
task that adds or changes a catalog entry, telemetry event or audit action,
refreshes the event reference in `docs/telemetry.md` in the same task, or
`test/kanban/telemetry_docs_test.exs` fails.

### G-A — Stream the Organization audit log to Splunk, Datadog and HTTPS endpoints

| # | Task | Size | Depends on |
| --- | --- | --- | --- |
| A1 | Add the `txid` column (with `lock_timeout`) and the concurrent index as two migrations, and document both database modes and the hardened apply-and-check procedure in `audit-log-database-roles.md` | medium | — |
| A2 | Add `Kanban.AuditStream.Reader`: the snapshot-horizon query with the `:horizon` option and `not_before`, redaction, personal data and excluded actions, with sandbox tests | medium | A1 |
| A3 | Add the commit-order race tests in the `_race` partition ([§14](#14-testing-strategy)) | small | A2 |
| A4 | Add the destinations, cursors, attempts and gaps tables, schemas and changesets, with encrypted fields, and read and validate `AUDIT_STREAM_MAX_DESTINATIONS` in `config/runtime.exs` | medium | — |
| A5 | Declare the four telemetry events and the new audit actions, with their labels translated, and refresh the `docs/telemetry.md` event reference | small | — |
| A6 | Add the `Kanban.AuditStream` context for destinations: create (with the start point), update, pause, resume, delete, rotate secret, with org-admin checks and the audit events | medium | A2, A4, A5 |
| A7 | Add `Kanban.AuditStream.Payload` and the adapter behaviour with the HTTPS adapter: gzip, HMAC with two secrets during a rotation (extending `Signer`), and Ed25519 over the decompressed body and destination id | medium | A2, **C1** |
| A8 | Add the Splunk HEC adapter, with the path check and classification by HEC code | small | A7 |
| A9 | Add the Datadog adapter, with the nine sites, `date`, the redacted `message`, tag limits and the 17-hour age | small | A7 |
| A10 | Add `DispatchWorker`: the lease, the pending batch, the cursor, 413 halving across runs, classification into states and `halted_reason`, `next_attempt_at`, the `txid` reset check, and the delivery telemetry | medium | A6, A7 |
| A11 | Add the `:audit_stream` queue, the `Scheduler` sweep, draining, catch-up pacing, the lag telemetry, and `AttemptPruneWorker`, with both cron entries | medium | A10 |
| A12 | Add the synthetic test event with its coarse result and per-Organization limit, and the status and lag functions, to the context | small | A8, A9, A10 |
| A13 | Record gaps: the retention steps in `Kanban.AuditStream.Retention` called from `Retention.PurgeWorker`, the Datadog too-old gaps, the throttles and the gap telemetry | medium | A10 |
| A14 | Add `Kanban.Release.reseed_audit_stream_cursors/0` and its runbook entry | small | A10 |

### G-B — Manage audit streaming in the Organization console

| # | Task | Size | Depends on |
| --- | --- | --- | --- |
| B1 | Move the private `with_org_admin/2` from the four `OrgLive` pages into one shared module, with no change in behaviour | small | — |
| B2 | Add the `/org/audit/streaming` list page with status, lag, hints, the one-org-admin warning and actions, and the buttons that link to it | medium | B1, **A12** |
| B3 | Add the destination form for all three types, with write-only secrets, start point (Datadog's two), personal data and excluded actions | medium | B2, **A8**, **A9** |
| B4 | Add the destination page with attempts, gaps and **Dismiss**, secret rotation, halted reasons, and **Retry now** and **Skip this batch** for a rejected batch | medium | B2, **A11**, **A13** |
| B5 | Add the org-admin emails through `Kanban.Notifications`: changes, catch-ups, failures, recoveries, gaps and the re-seed, with their throttles and translations | medium | **A6**, **A11**, **A13** |
| B6 | Write `docs/audit-log-streaming.md`, and update `docs/organizations.md`, the prose in `docs/telemetry.md` and `docs/README.md` | medium | B3, B4, **C5** |
| B7 | Add the Resources guide *Streaming your audit log to a security tool*, with screenshots in light and dark mode and translations | medium | B4 |
| B8 | Release prose and settings: the pricing page's Organization features (translated), `ROADMAP.md`, `CHANGELOG.md`, `priv/changelog/body.html`, and `min_machines_running` in `fly.production.toml` (D15) | small | B6, B7, **C4** |

### G-C — Sign Organization audit exports

| # | Task | Size | Depends on |
| --- | --- | --- | --- |
| C1 | Add `Kanban.AuditLog.Signing`: parsing the three `AUDIT_SIGNING_*` variables in `config/runtime.exs` with boot checks, the key id and fingerprint, the development key kept in `tmp/`, and the test key | medium | — |
| C2 | Publish the keys at `/.well-known/stride-audit-signing-keys` from a new public scope and `AuditSigningKeysController`: JWKS with the revoked list, single-key PEM by `kid`, and the cache header | small | C1 |
| C3 | Add the signed zip export to the org audit export controller, through a temporary file, with the manifest, `truncated` from the stream, the audit event's new keys, and the `docs/telemetry.md` refresh | medium | C1 |
| C4 | Add **Export signed (.zip)**, the key id, fingerprint and verification link to the audit log page | small | C3 |
| C5 | Write `docs/audit-log-signed-exports.md` with verification and the rotation and revocation runbook | small | C2, C3 |

**Dependencies between goals.** Bold entries above are in another goal. Stride
can't link tasks in different goals while creating them together, so the goals
are created one at a time, each after the goal it depends on, using the real
identifiers:

1. **G-C first.** It depends on nothing.
2. **G-A next**, with A7 depending on C1's identifier.
3. **G-B last**, with these eleven edges:
   - B2 → A12;
   - B3 → A8 and A9;
   - B4 → A11 and A13;
   - B5 → A6, A11 and A13;
   - B6 → C5;
   - B8 → C4.

Within a goal, dependencies use array positions as usual.

**Critical path:** A1 → A2 → A6 → A10 → A11 → B4 → B6 → B8.

---

## 17. Risks

| Risk | Mitigation |
| --- | --- |
| A long-open writing transaction anywhere on the database server, in any database, holds the horizon back and streaming stalls | `events_above_horizon` and the lag telemetry show it, and the destination page counts those events as waiting. The doc names `pg_stat_activity` rows with a `backend_xid` and `pg_prepared_xacts` as the first places to look ([§7.3](#73-what-it-costs)). Keep review apps and test databases off the production server |
| The database is moved logically and transaction ids restart lower | The worker detects it and halts each destination, and the operator re-seeds the cursors ([§8.8](#88-after-a-database-move)) |
| The `txid` migration fails on a hardened, self-hosted database | The deploy stops on `insufficient_privilege`, and the operator applies it with the admin URL and re-checks the hardening, as [§9.1](#91-a-commit-order-column-on-audit_events) describes. Rehearsed on a local hardened database, not a review app. On production's Managed Postgres it runs as usual |
| The `ALTER`s queue behind a long transaction and block audit inserts during a deploy | `lock_timeout` of 10 seconds; re-run when the transaction ends |
| Production's last machine stops while idle, and the sweep with it | D15: B8 sets `min_machines_running = 1`, so one machine always runs |
| Datadog drops events more than 18 hours old and still answers 202 | Never send one older than 17 hours; record the rest as a gap; the Failing email says so ([§5.2](#52-datadog-logs-intake)) |
| A destination tool changes its API | Each adapter is small and isolated, with its own tests and the generic HTTPS option as a fallback |
| Volume grows with large Organizations | Audit events are security events, so volume is low: thousands a day, not millions. Batches of 500, a queue of its own and a lease per destination keep the cost bounded |
| Org-admins ignore a Failing or paused destination until retention removes events | Emails on failing and on pausing, the gap record with its dates, the gap audit event, and the warning on the page until dismissed |
| An org-admin uses streaming to send the log elsewhere or to blind the SIEM | [§12.3](#123-abuse-by-an-org-admin): emails for every change that matters, catch-ups named, `audit_stream_*` not excludable, credential hints, and the one-org-admin warning |
| The signing key leaks | A leaked key lets anyone forge signed exports and signed HTTPS batches for every Organization on the instance. The runbook revokes it: it moves to `AUDIT_SIGNING_KEYS_REVOKED`, leaves the published set, and a new key is deployed. Exports signed with it are re-issued, and receivers are told its `kid`. For batches, the HMAC remains as a separate proof. Rotation (moving a key to "previous") is never used for a leak, because a previous key still verifies |
