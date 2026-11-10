# Audit Log Streaming — Implementation Design

**Roadmap item:** *Audit log streaming*, under *Planned*: "Send the audit log to a security tool such as Splunk, Datadog or a SIEM, and sign audit exports." ([ROADMAP](../../ROADMAP.md))

**Status:** Proposed design, not yet decomposed into tasks. The decisions in [§15](#15-decisions-needed) each carry a recommendation and still need to be settled.

**Date:** 2026-11-09

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
  order**, usually **within a minute** of happening.
- **No event is skipped.** That holds even when an event's transaction commits
  after events with later ids, and even when a destination is down for days.
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
  an Ed25519 signature that anyone can verify with `openssl` against a public
  key Stride publishes.

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
  contract. Streaming reads what it stores.

---

## 2. What already exists that streaming builds on

| Piece | Where | What streaming uses it for |
| --- | --- | --- |
| The `audit_events` table | `lib/kanban/audit_log/audit_event.ex`, migrations from `20261006102406` | The source of every streamed event. It is append-only, and its `organization_id` column scopes each row to an Organization |
| Append-only enforcement and ownership hardening | `lib/kanban/audit_log/hardening.ex`, [audit-log-hardening.md](../audit-log-hardening.md), [audit-log-database-roles.md](../audit-log-database-roles.md) | Rows cannot change after they are read, so a delivered event never goes stale. The migration in [§9.1](#91-a-commit-order-column-on-audit_events) must run as the owner role |
| Outside-actor redaction | `lib/kanban/audit_log/organization_scope.ex` | Applied to every streamed event, as on `/org/audit` |
| The export row shape | `Kanban.AuditLog.Export.row_map/1` | The base of the streamed payload ([§6](#6-the-event-payload)), so a streamed event and an exported one carry the same fields |
| The org audit export | `lib/kanban_web/controllers/org_audit_log_export_controller.ex` | The endpoint that gains a signed variant ([§11](#11-signed-audit-exports)) |
| Retention | `lib/kanban/retention/purge_worker.ex`, `audit_retention_days` on the security policy | Interacts with a destination that falls behind ([§8.6](#86-retention-and-a-destination-that-falls-behind)) |
| Webhook delivery | `lib/kanban/webhooks/` | `UrlGuard` (SSRF protection), `Transport` (Req pinned to the approved IP, no redirects, capped response) and `Signer` (HMAC-SHA256 `X-Stride-Signature`) are reused as they are |
| Encryption at rest | `Kanban.Encryption` and `Kanban.Encryption.EncryptedBinary` (AES-256-GCM, key from `ENCRYPTION_KEY`) | Destination URLs and credentials, as for the SSO client secret |
| The org-admin gate | `KanbanWeb.UserAuth` `:require_org_admin`, `with_org_admin/2` on each page | The new page and its events |
| Oban | `config/config.exs` | A new `:audit_stream` queue and one cron entry |
| Telemetry | `Kanban.Telemetry.emit/3`, `Kanban.Telemetry.Catalog` | Delivery events and the new audit actions ([§13](#13-telemetry-audit-events-notifications-and-docs)) |

The `:audit` plan feature is declared in `Kanban.Plans` but nothing checks it
today. [§4](#4-access-and-the-plan-gate) explains why streaming does not need
it either.

---

## 3. Streaming at a glance

```text
 Kanban.AuditLog.event/2
        │  inserts a row (txid = the inserting transaction's id)
        ▼
 audit_events ──────────────────────────────────────────────┐
        │                                                    │
        │ after commit: nudge                                │ every minute: sweep
        ▼                                                    ▼
 AuditStream.Scheduler ── one DispatchWorker job per destination with work waiting
        │
        ▼
 AuditStream.DispatchWorker (queue :audit_stream, one job per destination at a time)
   1. take the destination's lock
   2. read the next batch after its cursor, committed rows only (§7)
   3. redact, filter, and encode it for the destination (§5, §6)
   4. POST it through UrlGuard + Transport (§8)
   5. on 2xx: advance the cursor and record the attempt; if more is waiting, go again
      otherwise: record the attempt, keep the cursor, retry with backoff
```

There is no outbox table and no copy of the events. The audit log is the
queue, and each destination keeps only a cursor into it. A destination that is
down for a week simply has an older cursor; when it recovers, it catches up
from where it stopped.

---

## 4. Access and the plan gate

- **Who.** Only an enabled org-admin of the Organization can see or change its
  destinations, or download a signed export. The page uses
  `on_mount {KanbanWeb.UserAuth, :require_org_admin}` and re-reads the role
  from the database on every event with `with_org_admin/2`, like
  `OrgLive.Security`. The Organization's two-factor requirement applies, as it
  does to every `/org` page.
- **The plan.** An Organization is the paid plan, so every Organization can
  stream. No new plan feature is needed. If the `:audit` feature is ever wired
  up, the page checks it with surface `:live_view`, and the worker checks it
  with surface `:oban` before each delivery, which pauses the destination
  without losing its cursor.
- **Leaving the Organization.** Destinations belong to the Organization, not
  to the org-admin who created them. One org-admin leaving does not pause
  anything, unlike webhooks, which belong to the person who added them.
- **Deleting the Organization.** Its destinations, cursors and attempt history
  are deleted with it (`on_delete: :delete_all`).

---

## 5. Destinations

An Organization can have up to **3 destinations** (`AUDIT_STREAM_MAX_DESTINATIONS`,
default 3), for example one SIEM and one archive. Each has a type, a name the
org-admins choose, and the settings below.

### 5.1 Splunk (HTTP Event Collector)

| Setting | Notes |
| --- | --- |
| HEC URL | The full collector address, such as `https://http-inputs-acme.splunkcloud.com/services/collector/event` or `https://splunk.example.com:8088/services/collector/event`. Must be HTTPS with a certificate that verifies; there is no option to skip verification |
| HEC token | Sent as `Authorization: Splunk <token>`. Stored encrypted; shown afterwards only as its last 4 characters |
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

**Responses.** 200 with `"code":0` is success. 503 (server busy, code 9) and
5xx are retried. 400 (invalid data, code 6) means this batch can never
succeed; [§8.4](#84-retries-and-failure) says what happens then. 401 and 403
mean the token is wrong or disabled; the destination goes to *Failing* at
once and stays there until an org-admin fixes it. Indexer acknowledgement is
not used.

### 5.2 Datadog (Logs intake)

| Setting | Notes |
| --- | --- |
| Datadog site | One of `datadoghq.com`, `us3.datadoghq.com`, `us5.datadoghq.com`, `datadoghq.eu`, `ap1.datadoghq.com`, `ap2.datadoghq.com`, `ddog-gov.com`. Stride builds the URL `https://http-intake.logs.<site>/api/v2/logs` from it, so no free-form URL is entered |
| API key | Sent as `DD-API-KEY`. Stored encrypted; shown afterwards only as its last 4 characters |
| Service | Default `stride-audit` |
| Tags | Optional `key:value` pairs added to `ddtags`, after `source:stride` and `organization:<slug>` |

**Request.** `POST` with `Content-Type: application/json` and
`Content-Encoding: gzip`. The body is a JSON array of log entries:

```json
[{"ddsource":"stride","service":"stride-audit","hostname":"stridelikeaboss.com",
  "ddtags":"source:stride,organization:northwind-studio",
  "message":"member_added by alex@northwind.example",
  "stride":{...}}]
```

`stride` holds the payload from [§6](#6-the-event-payload), so Datadog indexes
its fields as attributes. `message` is a short English line for the log list.
Datadog takes at most 1,000 entries and 5 MB uncompressed per request, and
1 MB per entry; a Stride batch stays well inside all three ([§8.2](#82-batches)).

**Responses.** 202 is success. 429 and 5xx are retried. 413 halves the batch
and tries again. 400 is handled as in [§8.4](#84-retries-and-failure). 403
means the API key is wrong; the destination goes to *Failing* at once.

### 5.3 Any HTTPS endpoint

For every other tool. The endpoint receives Stride's own format and verifies
it the same way it would verify a Stride webhook.

| Setting | Notes |
| --- | --- |
| URL | HTTPS. Treated as a secret, because tools such as Sumo Logic put their token in the URL: stored encrypted, and shown afterwards as its host only |
| Format | **JSON batch** (default) or **NDJSON**, one event per line. Sumo Logic and Google Security Operations prefer NDJSON |
| Authorization header | Optional header name and value, such as `Authorization: Bearer …` or `X-goog-api-key: …`. The value is stored encrypted and shown afterwards only as its last 4 characters. Header names Stride sets itself are refused |
| Signing secret | Generated by Stride (`assec_` followed by 32 random bytes, base64url). Shown once, when the destination is created, and again only when an org-admin rotates it |

**Request.** `POST` with `Content-Type: application/json` (or
`application/x-ndjson`), `Content-Encoding: gzip`, and these headers:

| Header | Value |
| --- | --- |
| `X-Stride-Signature` | `t=<unix seconds>,v1=<hex HMAC-SHA256(secret, "<t>.<raw body>")>`, exactly as for webhooks. During a rotation it carries a second `v1=` for the new secret for 24 hours |
| `X-Stride-Batch` | The batch id, the same on every retry of the same batch |
| `X-Stride-Event-Count` | How many events the batch holds |
| `User-Agent` | `Stride-AuditStream/1` |

The JSON batch format is:

```json
{"version":1,"batch_id":"5f0c…","organization":{"id":210,"slug":"northwind-studio"},"events":[{...},{...}]}
```

The HMAC is computed over the raw, uncompressed body. A receiver verifies it
with the code in [Verify the signature](../webhooks.md#verify-the-signature).

**Responses.** Any 2xx is success. 408, 429 and 5xx are retried. 413 halves
the batch. Any other 4xx is handled as in [§8.4](#84-retries-and-failure).
Redirects are never followed.

### 5.4 Adding a destination type later

Each type is a module that implements a small behaviour:

```elixir
@callback validate(settings :: map()) :: :ok | {:error, keyword()}
@callback build_request(destination, [payload]) :: {url, headers, body}
@callback classify(status :: integer(), body :: binary()) ::
            :ok | :retry | :split | :permanent | :unauthorized
```

The worker owns reading, batching, retries, the cursor, telemetry and
attempts. A new type (syslog over TLS, S3, Sentinel) adds one module, its form
fields, and its tests.

---

## 6. The event payload

Every destination carries the same event object. It is
`Kanban.AuditLog.Export.row_map/1` plus the fields a tool outside Stride needs
to make sense of it:

```json
{
  "id": "1849230",
  "schema": "stride.audit.v1",
  "occurred_at": "2026-11-09T14:02:11.482913Z",
  "action": "member_added",
  "action_label": "Member added",
  "organization": {"id": 210, "slug": "northwind-studio", "name": "Northwind Studio"},
  "actor": {"user_id": 1153, "email": "alex@northwind.example", "in_organization": true},
  "ip": "203.0.113.24",
  "metadata": {"user_id": 1160, "role": "member"},
  "instance": "stridelikeaboss.com"
}
```

- **`id`** is the audit event's id, as a string so a 64-bit id survives
  JavaScript tools. With `instance` it is unique across Stride, and receivers
  use it to drop a duplicate delivered twice ([§8.3](#83-at-least-once-and-batch-identity)).
- **`schema`** names the version. A field may be added within `v1`; renaming or
  removing one makes `v2`, and destinations created before that keep `v1`
  until an org-admin switches them.
- **`action_label`** is the English label from
  `KanbanWeb.AuditLogActions`, never translated, so searches in the tool stay
  stable.
- **`actor`** follows the Organization audit page. For an actor from outside
  the Organization, `user_id`, `email` and `ip` are `null` and
  `in_organization` is `false` (`Kanban.AuditLog.OrganizationScope`).
- **`metadata`** is the stored, already-sanitised metadata
  ([§12.4](#124-what-is-never-sent)).
- **Personal data.** A destination can turn off **Include email and IP
  addresses**. Then `actor.email`, `ip` and any `email` key in `metadata`
  are `null`, and `actor.user_id` stays, so events can still be linked
  together. It is on by default, because a SIEM is usually where these
  questions are answered.

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
  AND txid < pg_snapshot_xmin(pg_current_snapshot())::text::bigint
  AND (txid, id) > ($cursor_txid, $cursor_id)
ORDER BY txid, id
LIMIT $batch_size
```

`pg_snapshot_xmin` is the oldest transaction still in progress. Every
transaction older than it has finished, committed or rolled back, so the set
of rows below it can never grow again. The cursor `(txid, id)` therefore only
moves forward over rows that are final, and a row that commits late is simply
read once its transaction is below the horizon. No row is skipped, and none is
read twice except by a retry.

This is a known Postgres pattern for transactional outboxes. It needs
Postgres 13 or later for `pg_current_xact_id()` and `pg_current_snapshot()`.
Development runs Postgres 14; production must be confirmed
([§15](#15-decisions-needed), D1).

### 7.3 What it costs

- **Lag follows the longest open transaction.** While any transaction anywhere
  in the database stays open, the horizon cannot pass it. Stride keeps
  transactions short, and the audit export already reads in keyset batches
  without a long transaction. The telemetry in [§13.1](#131-telemetry) records
  the lag, and the documentation names an idle-in-transaction session as the
  first thing to look for when it grows.
- **One index.** `(organization_id, txid, id)` keeps every read an index range
  scan.
- **Older rows.** Rows that exist before the migration get `txid = 0`
  ([§9.1](#91-a-commit-order-column-on-audit_events)), so they sort first, by
  id, and a catch-up reads them before anything new.

---

## 8. Delivery

### 8.1 Workers and scheduling

- **Queue.** A new Oban queue, `:audit_stream`, with a limit of 5.
- **`AuditStream.DispatchWorker`**: one job per destination, made unique on
  `destination_id` across `available`, `scheduled`, `executing` and
  `retryable`. It also takes `pg_try_advisory_xact_lock` on the destination
  while it works, so two runs can never send the same destination's events in
  parallel, even if uniqueness is bypassed.
- **Nudge.** After an Organization audit event commits, an after-commit hook
  (`Kanban.Telemetry.AfterCommit` has the pattern) inserts a dispatch job for
  each of that Organization's enabled destinations. Uniqueness makes repeated
  nudges free. This gives seconds of latency in the usual case.
- **Sweep.** `AuditStream.Scheduler`, an Oban cron job every minute, enqueues a
  dispatch job for every enabled destination with events waiting. That covers
  any nudge that was lost, such as one from a transaction that rolled back
  before a later commit.
- **Draining.** A run that sends a full batch and finds more waiting
  re-enqueues itself at once, so catching up a backlog does not wait for the
  next sweep.

### 8.2 Batches

A batch holds up to **500 events** and up to **1 MB** of uncompressed body,
whichever comes first. That is below Datadog's 1,000 entries and 5 MB, and
below the 1 MB default limit of many HTTP collectors. A single event is never
near either limit: metadata values are capped at 2,000 characters when they
are stored.

A 413 from the destination halves the batch and tries again, down to a single
event. A single event that still gets 413 is handled as a permanent rejection
([§8.4](#84-retries-and-failure)).

### 8.3 At-least-once and batch identity

Delivery is **at least once**. The cursor moves only after the destination
answers 2xx, so a crash between the answer and the cursor update sends the
batch again. Every event carries its stable `id`, and every batch its
`batch_id`, so the receiver can drop duplicates.

To make a retry resend exactly the same events, the cursor row keeps the
**pending batch**: its `batch_id` and its first and last `(txid, id)`. A retry
re-reads exactly that range, even if more events have arrived meanwhile. A new
batch is cut only once the pending one has succeeded or been given up.

### 8.4 Retries and failure

| Outcome | What happens |
| --- | --- |
| 2xx | Cursor moves past the batch. The attempt is recorded. `consecutive_failures` resets to 0 |
| Retryable (5xx, 408, 429, a timeout, a refused connection, a host that does not resolve) | The cursor stays. Retry with backoff of 15 s × 2^attempt with up to 20% jitter, capped at 15 minutes, honouring `Retry-After` when the destination sends one. The job never runs out of attempts: it ends, and the next sweep starts a new one |
| Unauthorized (401, 403) | The cursor stays. The destination is marked **Failing** at once and every org-admin is emailed. Delivery keeps trying at the capped interval, so it recovers by itself if the token is fixed at the tool's end |
| Permanent rejection (another 4xx for the whole batch, or 413 for one event) | The batch is retried 3 times over about 10 minutes in case it was transient. Then [§15](#15-decisions-needed) D3 applies |
| Blocked address (`UrlGuard` refuses every address the host resolves to) | The destination is marked **Failing**, with the reason shown, and nothing is sent until the URL is changed |

A destination is **Retrying** after its first failed attempt and **Failing**
after 30 minutes without a success, or at once on 401, 403 or a blocked
address. Org-admins are emailed when it becomes Failing and when it recovers,
at most once an hour each way. Nothing is ever turned off automatically:
events wait in the audit log, and a Failing destination resumes where it
stopped.

### 8.5 Starting point and catch-up

When an org-admin creates a destination, they choose where it starts:

- **From now** (default): the cursor is set to the current horizon.
- **From the last 24 hours**, **the last 7 days** or **everything the audit
  log holds**: the cursor is set to just before the oldest matching event, and
  the destination catches up batch by batch.

A catch-up is paced: a destination catching up sends at most one batch every
2 seconds, so a large Organization's history does not flood the tool or
crowd out other Organizations' live events.

### 8.6 Retention and a destination that falls behind

The daily retention job deletes Organization audit events older than the
Organization's retention period (90 days at the least). If a destination is
so far behind that its cursor is older than the cutoff, those events are
deleted before it sends them.

Retention is not held back for a failing destination: an Organization's
retention promise matters more. Instead:

- before purging an Organization, the retention job checks each of its
  destinations; for one whose cursor is older than the cutoff, it records how
  many events it will lose and the range, as an attempt with outcome `gap`;
- the destination page shows the gap, with its dates and the number of
  events;
- every org-admin is emailed;
- an `audit_stream_gap` audit event is recorded, so the gap itself reaches the
  destination once it recovers.

With a 90-day minimum, this needs a destination to have been failing, and
ignored after the emails, for three months.

### 8.7 Attempts history

Every send records an attempt: time, duration, event count, uncompressed
bytes, first and last event id, HTTP status, outcome and a short error. The
error is at most 200 characters, taken from Stride's own classification and
never from the response body, which can echo secrets or carry markup. Attempts
are kept for 7 days, and at most the newest 200 per destination; the cron job
`AuditStream.AttemptPruneWorker` prunes the rest every hour.

---

## 9. Data model

### 9.1 A commit-order column on `audit_events`

```sql
ALTER TABLE audit_events ADD COLUMN txid bigint NOT NULL DEFAULT 0;
ALTER TABLE audit_events ALTER COLUMN txid
  SET DEFAULT (pg_current_xact_id()::text::bigint);
CREATE INDEX CONCURRENTLY audit_events_org_txid_id_index
  ON audit_events (organization_id, txid, id);
```

- Adding the column with a constant default does not rewrite the table, and
  existing rows read as `0`. They are **not** updated, because the append-only
  trigger rejects updates, and nothing needs them to be.
- Setting the default afterwards gives every new row its transaction's id.
  `Kanban.AuditLog.AuditEvent` does not cast or set `txid`, so the database
  always fills it in and the app cannot forge one.
- `xid8` values are 64-bit and never wrap, so `bigint` holds them.
- The migration alters `audit_events`, so it runs as the owner role, as
  [Future migrations that alter audit_events](../audit-log-database-roles.md#future-migrations-that-alter-audit_events)
  requires. The index is built `CONCURRENTLY`, in its own migration with
  `@disable_ddl_transaction true`.
- Rows without an Organization (site events) also get a `txid`. It costs 8
  bytes a row and keeps the table uniform.

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
| `settings` | map | Non-secret settings by type: Datadog site, service and tags; Splunk index and source type; HTTPS format and header name |
| `credential` | `EncryptedBinary` | HEC token, Datadog API key or header value |
| `credential_hint` | string, 4 | Last 4 characters, for display |
| `signing_secret` | `EncryptedBinary` | HTTPS only |
| `previous_signing_secret` | `EncryptedBinary` | During a rotation |
| `previous_secret_expires_at` | utc_datetime | |
| `include_personal_data` | boolean, default true | [§6](#6-the-event-payload) |
| `excluded_actions` | `{:array, :string}` | Validated against the audit catalog |
| `schema_version` | integer, default 1 | |
| `state` | string | `healthy`, `retrying`, `failing` |
| `state_reason` | string | Short, from Stride's own classification |
| `failing_since` | utc_datetime | |
| `consecutive_failures` | integer | |
| `last_success_at` | utc_datetime | |
| `created_by_id` | FK users, `nilify_all` | For the record only |
| `lock_version` | integer | Optimistic locking for concurrent edits |
| timestamps | | |

### 9.3 `audit_stream_cursors`

Kept apart from the destination so the worker's frequent updates never
conflict with an org-admin editing the settings.

| Column | Type | Notes |
| --- | --- | --- |
| `destination_id` | PK, FK, `on_delete: :delete_all` | |
| `last_txid`, `last_event_id` | bigint | The last event delivered |
| `pending_batch_id` | uuid | [§8.3](#83-at-least-once-and-batch-identity) |
| `pending_first_txid`, `pending_first_id`, `pending_last_txid`, `pending_last_id` | bigint | The pending batch's range |
| `pending_attempts` | integer | |
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
| `outcome` | string: `delivered`, `retry`, `rejected`, `unauthorized`, `blocked`, `gap`, `skipped` |
| `error` | string, ≤ 200 |

Index `[destination_id, started_at]`.

### 9.5 Contexts and modules

| Module | Purpose |
| --- | --- |
| `Kanban.AuditStream` | The context: destinations (create, update, pause, resume, delete, rotate secret, send test), status and lag, attempts. Every function takes the scope first and checks org-admin |
| `Kanban.AuditStream.Destination`, `Cursor`, `Attempt` | Schemas and changesets |
| `Kanban.AuditStream.Reader` | The query in [§7.2](#72-the-approach-transaction-ids-and-the-snapshot-horizon), redaction and filtering |
| `Kanban.AuditStream.Payload` | [§6](#6-the-event-payload) |
| `Kanban.AuditStream.Adapter` and `Adapters.SplunkHec`, `Adapters.Datadog`, `Adapters.Https` | [§5](#5-destinations) |
| `Kanban.AuditStream.DispatchWorker`, `Scheduler`, `AttemptPruneWorker` | [§8](#8-delivery) |
| `Kanban.AuditLog.Signing` | [§11](#11-signed-audit-exports) |

`Kanban.AuditStream` is a new context rather than part of `Kanban.AuditLog`,
which is already large and has one job: recording and reading events.

---

## 10. Screens

All text is translated into every language Stride supports, and every screen
works in light and dark mode, using the tokens in the
[dark mode contract](../dark-mode-contract.md).

### 10.1 Where it lives

A new page, **Audit streaming**, at `/org/audit/streaming`
(`KanbanWeb.OrgLive.AuditStreaming`), in the existing
`live_session :require_authenticated_user` block next to `/org/audit`. It is
reached from a **Streaming** button in the header of the Organization audit
log page, beside **Export CSV** and **Export JSON**, and from the Organization
console's header buttons.

### 10.2 The destination list

Each destination shows as a row:

- its name and type (Splunk, Datadog, HTTPS endpoint) and its host;
- a status pill: **Healthy**, **Retrying**, **Failing** or **Paused**,
  with the reason for the last two;
- **Last delivered**: how long ago, and the time in UTC;
- **Behind by**: the number of events waiting and the age of the oldest, or
  **Up to date**;
- **Pause**/**Resume**, **Edit**, **Send test event** and **Delete**.

A note above the list states the limit: "An Organization can have up to 3
destinations." **Add destination** is disabled at the limit, and says why.

When a gap has occurred ([§8.6](#86-retention-and-a-destination-that-falls-behind)),
the destination's row shows a warning with the number of events lost and
their dates, until an org-admin dismisses it.

### 10.3 Adding or editing a destination

A form, using the core `<.input>` and `<.button>` components:

1. **Type**: Splunk, Datadog or HTTPS endpoint. The fields below change with
   it ([§5](#5-destinations)).
2. **Name**.
3. The type's settings. Secret fields are write-only: an existing value shows
   as "•••• 1a2b" with **Replace**, and is never sent back to the browser.
4. **Start from**: now, last 24 hours, last 7 days or everything the audit log
   holds. Shown only when creating.
5. **Include email and IP addresses**, on by default, with a line explaining
   what turning it off removes.
6. **Leave out these actions**: a multi-select of the actions, with their
   labels.

**Save** validates the settings, checks the URL with `UrlGuard`, and then
sends a test event. The destination is saved even if the test fails, and the
result is shown: "Test event delivered" or the classified error. For an HTTPS
destination, the signing secret is shown once, after the first save, with a
**Copy** button and the warning that it will not be shown again.

### 10.4 The destination's page

`/org/audit/streaming/:id` shows the settings, the status in full, the lag,
and the last 50 attempts as a table (time, events, size, status, outcome,
error). For HTTPS destinations it has **Rotate signing secret**, which keeps
the old secret valid for 24 hours and shows the new one once.

### 10.5 Confirmations

Deleting a destination, pausing it, and turning off personal data each ask
for confirmation. Deleting says that events will no longer be sent and that
the history of attempts goes too. Deleting does not delete anything already
in the destination tool.

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
| `README.txt` | How to verify, in four lines, with the `openssl` commands |

The plain **Export CSV** and **Export JSON** stay as they are. A signed export
counts towards the same rate limit (10 an hour per org-admin) and the same
50,000-row cap, and records the same `org_audit_log_exported` audit event with
`signed: true` in its metadata.

### 11.3 The manifest

```json
{
  "schema": "stride.audit-export.v1",
  "instance": "stridelikeaboss.com",
  "organization": {"id": 210, "slug": "northwind-studio", "name": "Northwind Studio"},
  "generated_at": "2026-11-09T15:20:04Z",
  "generated_by": {"user_id": 1153, "email": "alex@northwind.example"},
  "filters": {"action": null, "from": "2026-10-01", "to": "2026-10-31"},
  "file": {"name": "audit_log.csv", "format": "csv", "bytes": 482113,
           "sha256": "9f2c…"},
  "rows": 1834,
  "first_event": {"id": "1720044", "occurred_at": "2026-10-01T00:03:12Z"},
  "last_event": {"id": "1849230", "occurred_at": "2026-10-31T23:58:40Z"},
  "truncated": false,
  "key_id": "k1-3f9a1c0d2e4b5a67"
}
```

The file's SHA-256 is computed while it is streamed, so producing a signed
export reads the events only once. The manifest is written last, signed, and
added to the zip.

### 11.4 Keys

- **One signing key per Stride instance**, an Ed25519 key pair. Ed25519 is in
  Erlang's `:crypto` (`:crypto.sign(:eddsa, :none, msg, [priv, :ed25519])`),
  so no dependency is added.
- **Configuration.** `AUDIT_SIGNING_KEY` holds the private key, as PEM or as
  base64 of the 32-byte seed, read by `config/runtime.exs`. A value that is
  set but does not parse stops the boot, naming the variable and never
  printing it. When it is not set in production, signed exports are turned
  off and the boot logs a warning, as attachments do for local storage; the
  button then says "Signed exports are not set up on this server." In
  development and test, a key is generated at boot.
- **Key id.** `k1-` followed by the first 16 hex characters of the SHA-256 of
  the public key.
- **Publishing.** `GET /.well-known/stride-audit-signing-keys` returns the
  current public key and any previous ones as a JSON Web Key Set
  (`"kty":"OKP","crv":"Ed25519"`) and as PEM. It is public, needs no sign-in,
  and is cacheable for an hour. The Organization audit log page shows the
  current key id and fingerprint and links to it, so an auditor can record
  the fingerprint independently.
- **Rotation.** `AUDIT_SIGNING_KEYS_PREVIOUS` lists retired public keys, which
  stay published so old exports still verify. The operator runbook gives the
  steps: generate a key with `openssl genpkey -algorithm ed25519`, move the
  current public key to the previous list, set the new private key, deploy.

### 11.5 Verifying

The README in each zip, and the new doc, give:

```sh
# 1. Get the public key (or use the one you recorded earlier)
curl -s https://www.stridelikeaboss.com/.well-known/stride-audit-signing-keys?format=pem > stride-audit.pem
# 2. Check the signature on the manifest
openssl pkeyutl -verify -pubin -inkey stride-audit.pem -rawin -in manifest.json -sigfile manifest.json.sig
# 3. Check the file against the manifest
shasum -a 256 audit_log.csv     # must equal file.sha256 in manifest.json
```

The doc also gives a short Python example with the `cryptography` package for
people who want to automate the check.

### 11.6 What a signature proves, and what it does not

It proves that **this Stride instance produced these exact bytes** at the
stated time, for the stated Organization and filters. It does not prove the
export is complete beyond what the manifest says: a filtered or truncated
export says so in `filters` and `truncated`. Nor does it prove anything about
events the database held before they were exported; that is the job of the
append-only table and its hardening.

### 11.7 Later: a hash chain over the stored log

Outside this item, but designed to fit: each stored row would carry
`chain_hash = sha256(previous chain_hash ‖ canonical row)`, computed in commit
order by the same `txid` ordering as [§7](#7-reading-events-in-commit-order).
The manifest would then carry the chain hash of its last row, and streamed
events could carry theirs, so a destination could prove that nothing was
removed between two events. It needs its own design, because computing the
chain in commit order means a background job, not the insert.

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

### 12.2 Secrets

- URLs (for HTTPS and Splunk), tokens, API keys, header values and signing
  secrets are encrypted with `Kanban.Encryption` (AES-256-GCM, `ENCRYPTION_KEY`).
  Losing `ENCRYPTION_KEY` makes them unreadable; destinations then show
  **Failing** with "Credentials can't be read. Enter them again."
- Secrets are write-only in the UI and never logged, put in telemetry, put in
  audit metadata or shown in errors. Audit metadata names a destination by its
  id, type, name and host only.
- The signing private key lives only in the environment. It is never stored in
  the database or written to disk by Stride.

### 12.3 Abuse by an org-admin

A destination sends the Organization's security events, emails and IP
addresses to a place outside Stride. A compromised or malicious org-admin
account could use it to send them somewhere it should not. The design limits
and exposes that:

- only org-admins can create or change destinations, and the Organization's
  two-factor requirement applies;
- every change is an audit event, which the existing destinations also
  receive;
- **every org-admin is emailed** when a destination is created, its URL or
  credential is changed, personal data is turned on, or it is deleted, with
  who did it and the destination's host;
- a new destination starts **from now** unless the org-admin chooses
  otherwise, and the catch-up choice is in the audit event.

### 12.4 What is never sent

Streaming sends what the audit log stores. `Kanban.AuditLog.event/2` already
drops metadata keys whose names contain `password`, `token`, `secret`,
`authorization`, `key` or `otp`, caps every value, and replaces NUL. Streaming
adds the outside-actor redaction and the optional removal of email and IP
addresses. It never adds anything the Organization audit page does not show.

### 12.5 Load and fairness

- At most 3 destinations an Organization and 5 concurrent sends across the
  instance, on a queue of their own, so streaming cannot delay notifications,
  webhooks or exports.
- Catch-up is paced ([§8.5](#85-starting-point-and-catch-up)).
- **Send test event** is limited to 10 an hour per destination.

---

## 13. Telemetry, audit events, notifications and docs

### 13.1 Telemetry

Declared in `Kanban.Telemetry.Catalog`, in a new `AuditStreamEvents` module,
emitted with `Kanban.Telemetry.emit/3`, and tested with
`Kanban.TelemetryHelpers.attach_telemetry/2`:

| Event | Measurements | Metadata | Metric |
| --- | --- | --- | --- |
| `[:kanban, :audit_stream, :batch_delivered]` | `count`, `events`, `bytes`, `duration_ms` | `kind` | counter, sum of events, summary of duration, tagged by `kind` |
| `[:kanban, :audit_stream, :batch_failed]` | `count`, `duration_ms` | `kind`, `outcome` | counter tagged by `kind` and `outcome` |
| `[:kanban, :audit_stream, :lag_measured]` | `lag_seconds`, `events_waiting` | `kind` | summary tagged by `kind`, persisted, so a growing lag shows in the metrics history |
| `[:kanban, :audit_stream, :gap_recorded]` | `count`, `events` | `kind` | counter |

No metadata carries an Organization id, a URL, a host or an email address.
`docs/telemetry.md` gets the new events, and its event reference is
regenerated.

### 13.2 New audit actions

Added to `@audit_actions` in `Kanban.Telemetry.Catalog.Families`, with labels
in `KanbanWeb.AuditLogActions`:

| Action | Metadata |
| --- | --- |
| `audit_stream_destination_created` | `destination_id`, `kind`, `name`, `url_host`, `start_from`, `include_personal_data` |
| `audit_stream_destination_updated` | `destination_id`, `kind`, `changed` (field names only) |
| `audit_stream_destination_paused`, `_resumed`, `_deleted` | `destination_id`, `kind`, `name` |
| `audit_stream_signing_secret_rotated` | `destination_id` |
| `audit_stream_test_sent` | `destination_id`, `outcome` |
| `audit_stream_failing`, `audit_stream_recovered` | `destination_id`, `kind`, `reason` (no actor: recorded by the system) |
| `audit_stream_gap` | `destination_id`, `events`, `from`, `to` |

`org_audit_log_exported` gains `signed: true | false`.

### 13.3 Emails

Sent to every enabled org-admin of the Organization, through the existing
`UserNotifier` pattern, translated:

- a destination was created, deleted, or had its URL, credential or personal
  data setting changed (by whom, which destination, its host);
- a destination became Failing, and later recovered (at most once an hour
  each);
- a gap occurred.

### 13.4 Docs

- **New:** `docs/audit-log-streaming.md`, for org-admins and operators: setting
  up each destination type, the payload, verifying an HTTPS delivery, lag and
  failures, gaps, limits, and verifying a signed export. It is added to the
  index in `docs/README.md`.
- `docs/organizations.md`, *The Organization audit log*: streaming and signed
  exports, with links.
- `docs/audit-log-database-roles.md`: the `txid` migration as a worked example
  of a migration that alters `audit_events`.
- `docs/telemetry.md`: the new events and audit actions.
- An in-app Resources guide, *Streaming your audit log to a security tool*.
- `CHANGELOG.md`, `priv/changelog/body.html`, `ROADMAP.md` (move the item to
  Complete), and the Organization plan's feature list on the pricing page.

---

## 14. Testing strategy

| Area | Tests |
| --- | --- |
| Commit order | In the throwaway race database (`MIX_TEST_PARTITION=_race`, sandbox off): two transactions insert audit events and commit in the opposite order to their ids, with the reader running between the commits; the reader must return both, each once, in `(txid, id)` order. A long-open transaction holds the horizon back, and the reader returns nothing past it. A rolled-back event never appears. Repeated with many concurrent writers and a reader looping, checking that the delivered set equals the committed set with no duplicates |
| Migration | Existing rows read `txid = 0`; new rows get a real transaction id; the app cannot set `txid`; the migration runs under the hardened owner role |
| Reader | Organization scoping, redaction of outside actors, the personal-data switch, excluded actions, batch size and byte limits |
| Adapters | Each type's request (URL, headers, gzip body, HMAC) against `Req.Test` stubs, and each response classified correctly, including 413 splitting |
| Worker | Cursor moves only on 2xx; a retry resends exactly the pending batch; uniqueness and the advisory lock prevent parallel runs; state moves Healthy → Retrying → Failing → Healthy with the right emails; catch-up pacing; nudge after commit and sweep |
| Retention | A destination behind the cutoff records a gap, an audit event and an email, and retention still purges |
| Security | `UrlGuard` refusals at save and send time; secrets never appear in rendered HTML, logs, telemetry or audit metadata; a non-org-admin, and an org-admin of another Organization, get nothing; a reserved header name is refused |
| UI | The LiveView in both locales' plural forms, write-only secret fields, the limit of 3, confirmations, and light and dark mode |
| Signed exports | The zip's contents; the manifest's SHA-256 matches the file; the signature verifies with `:crypto` and with the `openssl` command in the README (in a test tagged to run where `openssl` exists); a changed byte fails verification; the key endpoint's JWKS and PEM; boot refuses a malformed key and warns on a missing one |
| Telemetry | Catalog entries, call sites, and no forbidden keys, by the existing telemetry tests |

Before release, an exploratory session sends real events to a Splunk Cloud
trial, a Datadog trial and a local HTTPS receiver, stops each one for a while,
and checks that nothing is lost or duplicated beyond what `id` resolves.

---

## 15. Decisions needed

| # | Decision | Recommendation |
| --- | --- | --- |
| D1 | Production must run Postgres 13 or later for `pg_current_xact_id()`. | Confirm the Fly Postgres version before G-A starts. If it is older, upgrade first; the time-window fallback in [§7.1](#71-the-problem) is not safe enough to ship |
| D2 | Should the limit be 3 destinations per Organization? | Yes, configurable with `AUDIT_STREAM_MAX_DESTINATIONS` |
| D3 | A batch the destination rejects permanently (a 4xx other than 401, 403, 408, 413 or 429, three times): stop the destination, or skip the batch? | **Stop.** Mark the destination Failing and keep the cursor, so nothing is lost; the page offers **Skip this batch**, which records an attempt with outcome `skipped` and an audit event. Skipping on its own would silently lose events |
| D4 | Should **Include email and IP addresses** default to on? | Yes: the destination is a security tool, and the Organization audit page shows the same data to the same people |
| D5 | Should the stream also carry an Ed25519 signature, so a receiver needs no shared secret? | Not in v1. HMAC matches webhooks, and receivers already have code for it. Add it with the hash chain ([§11.7](#117-later-a-hash-chain-over-the-stored-log)) if customers ask |
| D6 | Signed exports: one key per instance, or one per Organization? | One per instance. Per-Organization keys add key management for no gain in what the signature proves |
| D7 | Should signed exports be the only kind? | No. Keep plain CSV and JSON for people who just want to read the log |
| D8 | Should a site admin be able to see an Organization's destinations? | No, as with the rest of the Organization console |

---

## 16. Goals, tasks and order

Three goals. Each task is about 1 to 3 hours.

### G-A — Stream the Organization audit log to Splunk, Datadog and HTTPS endpoints

| # | Task | Size | Depends on |
| --- | --- | --- | --- |
| A1 | Add `txid` and its index to `audit_events` as the owner role, and document the migration | small | D1 |
| A2 | Add `Kanban.AuditStream.Reader` with the snapshot-horizon query, redaction and filters, and the race tests | medium | A1 |
| A3 | Add the destinations, cursors and attempts tables, schemas and changesets, with encrypted fields | medium | — |
| A4 | Add the `Kanban.AuditStream` context: create, update, pause, resume, delete, rotate, test, status and lag, with org-admin checks and the new audit actions | medium | A3 |
| A5 | Add `Kanban.AuditStream.Payload` and the adapter behaviour with the HTTPS adapter | medium | A2 |
| A6 | Add the Splunk HEC adapter | small | A5 |
| A7 | Add the Datadog adapter | small | A5 |
| A8 | Add `DispatchWorker`, the after-commit nudge, the `Scheduler` sweep, the queue, retries, states, pacing and the attempt prune job | large → split into A8a (worker and cursor) and A8b (scheduling, states, pruning) | A4, A5 |
| A9 | Record retention gaps in `Retention.PurgeWorker` | small | A8a |
| A10 | Add the telemetry events and the catalog entries, and regenerate the event reference | small | A8a |

### G-B — Manage audit streaming in the Organization console

| # | Task | Size | Depends on |
| --- | --- | --- | --- |
| B1 | Add the `/org/audit/streaming` list page with status, lag and actions, and the buttons that link to it | medium | A4 |
| B2 | Add the destination form for all three types, with write-only secrets, start point, personal data and excluded actions | medium | B1, A6, A7 |
| B3 | Add the destination page with attempts, secret rotation, gap warnings and **Skip this batch** | medium | B1, A8b |
| B4 | Add the org-admin emails for changes, failures, recoveries and gaps | small | A8b, A9 |
| B5 | Write `docs/audit-log-streaming.md`, update `docs/organizations.md`, `docs/telemetry.md` and `docs/README.md`, and add the Resources guide | medium | B2, B3 |

### G-C — Sign Organization audit exports

| # | Task | Size | Depends on |
| --- | --- | --- | --- |
| C1 | Add `Kanban.AuditLog.Signing` with key loading from `AUDIT_SIGNING_KEY`, the key id, rotation, and boot checks | small | — |
| C2 | Publish the keys at `/.well-known/stride-audit-signing-keys` as JWKS and PEM | small | C1 |
| C3 | Add the signed zip export to the org audit export controller, with the manifest computed while streaming | medium | C1 |
| C4 | Add **Export signed (.zip)**, the key fingerprint and the verification link to the audit log page | small | C3 |
| C5 | Document verification and the operator's key rotation runbook | small | C3 |

G-C does not depend on G-A or G-B and can run first or in parallel. The
release, with the CHANGELOG, ROADMAP and pricing updates, follows the last of
the three goals.

**Critical path:** A1 → A2 → A5 → A8a → A8b → B3 → B5.

---

## 17. Risks

| Risk | Mitigation |
| --- | --- |
| A long-open transaction holds the horizon back and streaming stalls | Lag telemetry and the destination page show it. The doc names idle-in-transaction sessions as the first thing to check. Stride's own code keeps transactions short |
| The `txid` migration fails on production because of the hardened ownership | Run it as the owner role, as the database-roles doc requires; rehearse it on the review app first |
| A destination tool changes its API | Each adapter is small and isolated, with its own tests and the generic HTTPS option as a fallback |
| Volume grows with large Organizations | Audit events are security events, so volume is low: thousands a day, not millions. Batches of 500, a queue of its own and a per-destination lock keep the cost bounded |
| Org-admins ignore a Failing destination until retention removes events | Emails on failing, the gap record, the gap audit event and the warning on the page |
| The signing key leaks | Rotation keeps old exports verifiable, and the runbook covers retiring a leaked key. The key never leaves the environment |
