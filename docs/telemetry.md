# Telemetry Events

This document describes how the kanban app declares and emits its
[`:telemetry`](https://hexdocs.pm/telemetry/) events. Introduced by W2336, it
covers the foundation every later telemetry task builds on: one catalog of
events, one emit path that enforces it, and one test helper.

Every event the app emits goes through `Kanban.Telemetry`. Since W2337 no
code outside `lib/kanban/telemetry.ex` calls `:telemetry.execute/3` or
`:telemetry.span/3` directly, and a test fails if one does (see
[Checking the call sites](#checking-the-call-sites)).

## The catalog

`Kanban.Telemetry.Catalog` (`lib/kanban/telemetry/catalog.ex`) is the single
list of events. It is plain data, so metrics definitions, documentation and
tests can be generated from it:

- `Kanban.Telemetry.Catalog.events/0` returns every entry.
- `Kanban.Telemetry.Catalog.fetch/1` looks one up by name.

Each entry is a map with these fields:

| Field | Meaning |
|---|---|
| `name` | The full event name, such as `[:kanban, :task, :archived]` |
| `kind` | `:event` for a single event, or `:span` for a span prefix |
| `domain` | The area of the app; always the second segment of `name` |
| `measurements` | The measurement keys the event carries |
| `metadata` | The metadata keys the event may carry; anything else is dropped |
| `description` | One sentence saying what happened |
| `legacy` | `true` for an event whose name predates the catalog |

### Naming rule

A new event is named `[:kanban, domain, past_tense_action]`, for example
`[:kanban, :task, :archived]`. The domain is a singular noun (`:task`,
`:board`, `:user`, `:api`), and the action is a past-tense verb or verb phrase.
A span prefix names the operation being timed, `[:kanban, domain, operation]`,
or `[:kanban, domain]` when the domain is itself the operation, as in
`[:kanban, :export]`. `:telemetry` appends `:start`, `:stop` and `:exception`
to it, so the emitted names still have three segments.

Legacy entries keep their existing names, such as `[:kanban, :board, :creation]`,
even where they break the naming rule, because metrics, dashboards and the
stored `metrics_events` history depend on them. Never rename one.

### Runtime-named families

Two families build their event name from an action atom at runtime. Each
action has its own catalog entry, generated from a list of
`{action, metadata keys, description}` tuples in
`Kanban.Telemetry.Catalog.Families` (`lib/kanban/telemetry/catalog/families.ex`),
which the catalog appends to its own list:

- `[:kanban, :api, action]`, from `KanbanWeb.API.TaskActions.emit_telemetry/3`
  (the `@api_actions` list). Every entry also declares `board_id`, `user_id`,
  `path` and `method`, which `emit_telemetry/3` adds.
  `Kanban.Metrics.UserActivity` counts the stored `kanban.api.task_*` events
  per `user_id` for the admin users page, so `user_id` must stay.
- `[:kanban, :audit, action]`, from `Kanban.AuditLog.event/2` (the
  `@audit_actions` list). See [Audit events](#audit-events).

## Event data rules

These rules were applied to the existing events in W2337:

- **Ids are metadata, never measurements.** A measurement is a number to add
  up or average; a task id is a label. The task events `archived`,
  `unarchived`, `completed`, `moved_to_review` and `returned_to_doing` measure
  `count: 1` and carry `task_id` in their metadata.
- **Measurements are numbers or absent.** `[:kanban, :task, :moved_to_review]`
  measures `time_spent_minutes` as the integer saved on the task, and leaves
  it out when there is none, never a string or `nil`.
- **`[:kanban, :user, :login]` counts real sign-ins only.** It is emitted from
  `KanbanWeb.UserAuth.log_in_user/3`, so renewing an old session token does not
  count as a login.
- **No free text from agents.** `[:kanban, :api, :task_unclaimed]` does not
  carry the unclaim `reason`; the unclaim notification and the application
  log still do.

The task lifecycle events are emitted through `Kanban.Tasks.TaskTelemetry`.

### Audit events

`Kanban.AuditLog.event/2` records each security event three ways. The stored
`audit_events` row and the `security_audit` log line are the compliance record
and keep the actor's `email` and `ip`. The telemetry copy can leave the app,
so it never carries `email`, `ip` or the export `filters` (which can contain
an email).

The audit emit passes `strict: false`, because `event/2` must never crash its
caller: an action or key missing from the catalog is logged and dropped there,
not raised. The call-site test below covers the audit actions instead.

Open question: `[:kanban, :audit, :sudo_mode_entered]` fires on every mount of
a LiveView that requires sudo mode, not only when sudo mode starts, so its
volume is high. W2337 leaves it unchanged.

### Board, membership and column events

W2339 added these events. Each one is emitted only after its change has been
saved, so a refused, invalid or rolled-back change emits nothing, and neither
does an update that changes no field. Every event measures `count: 1`, except
`token_bulk_revoked` and `column.reordered`, described in the notes below the
table.

| Event | Metadata | Emitted by |
|---|---|---|
| `[:kanban, :board, :updated]` | `board_id`, `actor_user_id`, `fields` | `Kanban.Boards.update_board/3` |
| `[:kanban, :board, :deleted]` | `board_id`, `actor_user_id` | `Kanban.Boards.delete_board/2` |
| `[:kanban, :board, :field_visibility_changed]` | `board_id`, `actor_user_id`, `fields` | `Kanban.Boards.update_field_visibility/3` |
| `[:kanban, :board, :member_added]` | `board_id`, `user_id`, `access`, `actor_user_id` | `Kanban.Boards.add_user_to_board/4` |
| `[:kanban, :board, :member_removed]` | `board_id`, `user_id`, `access`, `actor_user_id` | `Kanban.Boards.remove_user_from_board/3` |
| `[:kanban, :board, :member_access_changed]` | `board_id`, `user_id`, `from_access`, `to_access`, `actor_user_id` | `Kanban.Boards.update_user_access/4` |
| `[:kanban, :api, :token_bulk_revoked]` | `board_id`, `user_id`, `actor_user_id`, `reason` | `Kanban.ApiTokens.report_bulk_revocation/5` |
| `[:kanban, :column, :created]` | `board_id`, `column_id`, `actor_user_id` | `Kanban.Columns.create_column/3` |
| `[:kanban, :column, :updated]` | `board_id`, `column_id`, `actor_user_id`, `fields` | `Kanban.Columns.update_column/3` |
| `[:kanban, :column, :deleted]` | `board_id`, `column_id` | `Kanban.Columns.delete_column/1` |
| `[:kanban, :column, :reordered]` | `board_id` | `Kanban.Columns.reorder_columns/2` |

- **`fields` holds names only.** `board.updated` and `column.updated` list the
  changed field names as atoms, and `board.field_visibility_changed` lists the
  shown or hidden field names as strings. A board or column name, a
  description or any other value never appears.
- **Membership events** come from `Kanban.Boards.BoardTelemetry`, called by
  `Kanban.Boards.MembershipChanges` once the membership change has committed.
  They fire even when an owner changes their own membership, which sends no
  notification. `user_id` is the member, `actor_user_id` the owner who made the
  change, and `access`, `from_access` and `to_access` are `:owner`, `:modify`
  or `:read_only`. For `member_removed`, `access` is the level the member held.
- **`token_bulk_revoked` counts revoked tokens.** Its `count` is the number of
  tokens revoked, and it is 0 when the member had none. `reason` is
  `:member_removed`, or `:read_only_access` when an access save leaves the
  member at `:read_only`. `Kanban.ApiTokens.revoke_user_tokens_for_board/2`
  runs inside the membership transaction, so it emits nothing itself; the event
  is sent after the commit. Saving `:read_only` again for a member who still
  had tokens emits only this event, with no `member_access_changed`.
- **`column.reordered`** measures `count: 1` and `column_count`, the number of
  column ids given. It is emitted for every reorder that commits, even one that
  keeps the current order.
- **No actor on two column events.** `delete_column/1` and `reorder_columns/2`
  are not given the acting user, so `column.deleted` and `column.reordered`
  carry no `actor_user_id`.
- **Cascades emit nothing extra.** Deleting a board emits only `board.deleted`,
  not a `member_removed` per member, and deleting a column emits only
  `column.deleted`, not an event per task. Creating an AI-optimized board emits
  `[:kanban, :board, :creation]` and one `column.created` per default column.

### Export, rate-limit, MCP, GitHub and API auth events

W2343 added these. Two of them are spans: their `:start`, `:stop` and
`:exception` events measure how long the work took.

| Event | Kind | Metadata | Emitted by |
|---|---|---|---|
| `[:kanban, :export]` | span | `kind`, `format` | `Kanban.Archives.export_csv_for_board/1` and the metrics, workspace metrics and audit log export controllers |
| `[:kanban, :rate_limit, :denied]` | event | `surface` | `Kanban.RateLimit.check/2` and `peek/2` |
| `[:kanban, :mcp, :request]` | span | `method`, `outcome` | `KanbanWeb.MCP.Server` |
| `[:kanban, :github, :issue_created]` | event | `outcome` | `Kanban.GitHub.create_issue/3` |
| `[:kanban, :api, :auth_failed]` | event | `reason`, `path`, `method` | `KanbanWeb.Plugs.AuthenticateApiToken` |

- **Exports.** `kind` is `:archive_csv` (board archive CSV), `:metrics_pdf`
  (board metrics report), `:workspace_metrics` (workspace metrics report) or
  `:audit_log`. `format` is `:csv`, `:pdf`, `:xlsx` or `:json`. The stop event
  also measures `row_count` for `:archive_csv`, the number of archived tasks
  exported; the other exports have no row count to report. A board, its
  name, the metric filters and the audit-log filters never appear, nor the
  admin's IP address. A failed metrics report that redirects with an error
  still ends with a stop event; only an exception produces the exception
  event.
- **On an exception**, `:telemetry` replaces `kind` with the error class
  (`:error`, `:exit` or `:throw`) and adds `reason` and `stacktrace`; `format`
  is kept. Match the exception to its start with `telemetry_span_context`.
- **Rate-limit denials** carry only `surface`, such as `:login`, `:reset` or
  `:api_token`. The rate-limit key, IP address and identity are never sent,
  not even hashed, because a key is often an email or an IP address. Every
  denied `check/2` or `peek/2` emits one event; `record_failure/2` discards its
  verdict and never emits.
- **MCP requests.** Every JSON-RPC message is one span, so a batch emits one
  per message. `method` is `:initialize`, `:ping`, `:tools_list`,
  `:tools_call`, `:notification`, `:response` or `:unknown`; the method or
  tool name the client sent is never emitted. The stop event adds `outcome`:
  `:ok`, `:parse_error`, `:invalid_request`, `:invalid_params`,
  `:unknown_method`, `:unknown_tool` or `:tool_error` (a tool that ran and
  returned `isError`). A body rejected before any message is read, including
  malformed JSON, is one span with `method: :unknown`. Requests stopped by the
  transport checks before the server sees them (a missing token, a foreign
  `Origin`, a wrong content type or protocol version) emit no MCP span; a
  missing or bad token emits `[:kanban, :api, :auth_failed]` instead.
  `[:kanban, :api, :mcp_tool_called]` is unchanged.
- **GitHub issues.** `outcome` is `:ok` or `:error`. An issue report made while
  the GitHub integration is not configured counts as `:error`. The title,
  body, labels, issue URL and error text are never emitted.
- **`missing_token`** is a new `reason` for `[:kanban, :api, :auth_failed]`,
  sent when an API request has no `Authorization` header or one that is not a
  `Bearer` header. The other reasons are `rate_limited`, `token_not_found`,
  `token_revoked`, `token_expired` and `user_disabled`.

### Task activity events

W2340 added these. They are declared in
`Kanban.Telemetry.Catalog.TaskEvents` (`lib/kanban/telemetry/catalog/task_events.ex`)
and emitted by `Kanban.Tasks.TaskTelemetry` in the task context, so the board
UI, the REST API and the MCP server each produce one event per change. Each is
emitted only after its change has been saved, so a refused, invalid or
rolled-back change emits nothing. Every event measures `count: 1`;
`reordered` also measures `task_count` for a whole-column reorder.

| Event | Metadata | Emitted by |
|---|---|---|
| `[:kanban, :task, :updated]` | `task_id`, `board_id`, `fields`, `source`, `actor_user_id` | `Kanban.Tasks.update_task/3` (`source: :ui`) and `api_update_task/2` (`:api`) |
| `[:kanban, :task, :moved]` | `task_id`, `board_id`, `from_column_id`, `to_column_id` | `Kanban.Tasks.move_task/3`, to another column |
| `[:kanban, :task, :reordered]` | `task_id`, `column_id`, `board_id` | `Kanban.Tasks.move_task/3` within one column, and `reorder_tasks/2` (no `task_id`) |
| `[:kanban, :task, :deleted]` | `task_id`, `board_id` | `Kanban.Tasks.delete_task/1` |
| `[:kanban, :task, :claimed]` | `task_id`, `board_id`, `user_id` | `Kanban.Tasks.AgentWorkflow.claim_next_task/5` |
| `[:kanban, :task, :unclaimed]` | `task_id`, `board_id`, `user_id`, `has_reason` | `Kanban.Tasks.AgentWorkflow.unclaim_task/3` |
| `[:kanban, :task, :claim_expired]` | `task_id`, `board_id`, `user_id` | `Kanban.Notifications.ClaimExpiryWorker` |
| `[:kanban, :task, :review_approved]` | `task_id`, `board_id`, `reviewer_user_id` | `Kanban.Reviews.approve_review/3` |
| `[:kanban, :task, :review_changes_requested]` | `task_id`, `board_id`, `reviewer_user_id` | `Kanban.Reviews.request_changes_review/3` |
| `[:kanban, :task, :comment_created]` | `task_id`, `board_id`, `comment_id`, `user_id`, `by_agent` | `Kanban.Tasks.create_comment/4` |

- **`fields` holds names only.** `updated` lists the changed field names as
  atoms, sorted, and is not emitted for an update that changes nothing.
  `actor_user_id` is the editing user when the caller passes one, otherwise
  `nil`. A goal whose assignment cascades to its children emits one `updated`,
  for the goal.
- **Claims are counted once per path.** REST and MCP claims both go through
  `claim_next_task/5`, which emits `task.claimed` once. A REST or MCP claim
  also emits `[:kanban, :api, :task_claimed]`, as before: `api.*` events count
  requests and `task.*` events count state changes, so both firing is
  intended. The same holds for `unclaimed` and `[:kanban, :api, :task_unclaimed]`.
  A failed claim, or one with no task available, emits nothing.
- **`has_reason` replaces the reason.** `unclaimed` says whether a non-blank
  reason was given; the reason itself is never sent.
- **`claim_expired` is emitted once per claim.** The sweeper sees an expired
  claim on every run in its two-hour window, so it records each claim (task id
  and `claim_expires_at`) in the `claim_expiry_reports` table against a unique
  index and emits only when the row is new. A re-run, a restart or a second
  node therefore never emits twice, and a new claim on the same task is counted
  again. It is emitted even when the assignee left the board and gets no
  notification. Rows older than the window plus a day are pruned on each run.
- **Review events never carry the notes.** `reviewer_user_id` is the reviewer.
  An approval still emits `[:kanban, :task, :completed]` once, through
  `mark_reviewed`; no second completion event is added.
- **`comment_created` never carries the comment text.** `user_id` is the
  author and `by_agent` is `true` when an agent wrote it.
- **Not covered.** Bulk moves, assignments and labels from
  `Kanban.Tasks.BulkActions`, automatic goal repositioning, the automatic
  deletion of an empty parent goal, the sibling position shifts after a
  delete, cascaded children, and comment edits and deletions emit none of
  these events.

## Emitting an event

```elixir
Kanban.Telemetry.emit([:kanban, :task, :changed_files_missing], %{count: 1},
  task_id: task.id, identifier: task.identifier, board_id: board_id)

Kanban.Telemetry.span([:kanban, :export], %{kind: :archive_csv, format: :csv}, fn ->
  rows = list_archived_for_board(board_id)
  {build_csv(rows), %{row_count: length(rows)}, %{kind: :archive_csv, format: :csv}}
end)
```

`emit/3` wraps `:telemetry.execute/3`, and `span/3` wraps `:telemetry.span/3`
with the same semantics, so `Telemetry.Metrics` duration summaries work
unchanged. Measurements and metadata may be maps or keyword lists. The span's
function returns `{result, stop_metadata}`, or
`{result, extra_stop_measurements, stop_metadata}` as above, and `span/3`
returns `result`. The stop event carries only the metadata the function
returns, so repeat any start key the stop event needs.

### Metadata filtering

Before an event is emitted, its metadata is filtered:

- **Forbidden keys are always dropped**, in every environment, even when a
  catalog entry declares them. `Kanban.Telemetry.forbidden_key?/1` matches
  personal data (`email`, `ip`, `ip_address`, `remote_ip`, `title`,
  `description`, `body`, `token`) and any key containing `email`, `password`,
  `secret`, `token`, `authorization` or `api_key`. A key ending in `_id`, such
  as `token_id`, is a row id and is allowed.
- **Undeclared keys**, ones the entry does not list, are dropped.
- Each drop is logged as a warning and reported as a
  `[:kanban, :telemetry, :metadata_dropped]` event. Both carry the key names
  only, never the values.

On an exception inside `span/3`, `:telemetry` adds its standard `kind`,
`reason` and `stacktrace` keys to the exception event. Those are not filtered,
and `reason` can quote data from the failed operation, so anything that exports
events out of the app must not send `reason` or `stacktrace` verbatim.

### Strict mode

Strict mode is on only in `config/test.exs`:

```elixir
config :kanban, Kanban.Telemetry, strict: true
```

In strict mode an undeclared event or an undeclared metadata key raises
`ArgumentError`, so the test that made the mistake fails. Forbidden keys are
still dropped rather than raised.

Outside strict mode `emit/3` never raises: an undeclared event is logged and
skipped, an undeclared key is dropped, and metadata that is neither a map nor a
keyword list is treated as empty. Passing `strict: false` turns strict mode off
for one call. No option turns it on, so production code cannot be made to
raise.

## Adding an event

1. Add an entry to the list in `Kanban.Telemetry.Catalog`, with every field,
   following the naming rule and declaring no forbidden key. A new API or
   audit action is a new tuple in `@api_actions` or `@audit_actions` in
   `Kanban.Telemetry.Catalog.Families`, and a new task activity event is an
   entry in `Kanban.Telemetry.Catalog.TaskEvents`.
2. Emit it with `Kanban.Telemetry.emit/3` or `Kanban.Telemetry.span/3`.
3. Test it with the helper below. `test/kanban/telemetry_test.exs` fails if an
   entry is missing a field, repeats a name, or declares a forbidden key.

## Checking the call sites

`Kanban.TelemetrySourceScan` (`test/support/telemetry_source_scan.ex`) parses
every `.ex` file under `lib/` and finds each `Kanban.Telemetry.emit/3` and `span/3`
call, each `emit_telemetry(conn, action, metadata)` API call and each
`AuditLog.event(action, metadata)` call. Two tests use it:

- `test/kanban/telemetry_test.exs`, "every emitted event is in the catalog",
  fails when a call site emits an event that is not catalogued, or sends a
  literal metadata key its entry does not declare.
- `test/kanban/telemetry/emit_sites_test.exs` fails when code outside
  `lib/kanban/telemetry.ex` calls `:telemetry.execute` or `:telemetry.span`,
  when an event name is built at runtime anywhere but the API and audit
  emitters, when a catalog entry has no call site, or when a
  `kanban.api.task_*` entry stops declaring `user_id`.

Pass API and audit action names as literal atoms, so the scan can see them.

## Metrics retention

`KanbanWeb.Telemetry.MetricsStorage` stores persisted metrics in the
`metrics_events` table. Since W2345 they are not kept forever:
`Kanban.Metrics.RetentionWorker` (`lib/kanban/metrics/retention_worker.ex`), a
daily Oban cron job at 03:23 UTC on the `:maintenance` queue, removes rows
whose `recorded_at` is older than the retention period. A row recorded exactly
at the cutoff is kept.

```elixir
config :kanban, Kanban.Metrics.RetentionWorker, retention_days: 90, batch_size: 1_000
```

- `retention_days` defaults to 90 in `config/config.exs` and is read each time
  the job runs. A missing value, or one that is not a positive whole number,
  removes nothing and logs a `metrics retention skipped` warning.
- Rows are removed `batch_size` at a time, one `DELETE` per batch, so a large
  backlog never holds one long lock. An invalid `batch_size` falls back to
  1,000.
- The job never touches `audit_events`, which has its own retention rules and
  database roles (see [Audit log hardening](audit-log-hardening.md)).
- `Kanban.Metrics.UserActivity`, behind the admin users page, reads
  `metrics_events`, so its counts cover the retention period only.

When it finishes, the job emits `[:kanban, :metrics, :retention_completed]`:

| Field | Value |
|---|---|
| `count` (measurement) | Rows removed |
| `batches` (measurement) | `DELETE` batches run; an empty table runs one |
| `retention_days` (metadata) | The retention period used |

A run skipped for an invalid setting emits nothing.

## Testing events

`Kanban.TelemetryHelpers` (`test/support/telemetry_helpers.ex`) attaches a
handler for a test:

```elixir
import Kanban.TelemetryHelpers

test "reports a missing diff" do
  attach_telemetry([:kanban, :task, :changed_files_missing])

  ChangedFilesAudit.audit_review_bound_task(task, 55)

  assert_receive {:telemetry_event, [:kanban, :task, :changed_files_missing],
                  %{count: 1}, %{task_id: 7}}
end
```

`attach_telemetry/2` takes one event or a list of events. It uses a unique
handler id and detaches the handler in `on_exit`, so async tests never collide
on an id. Telemetry dispatch is global, so it also forwards an event only when
the test process emitted it, or a process the test started (one that lists the
test in `$callers`, such as a `Task`). For events from unrelated processes,
such as an Oban job or a GenServer, pass `any_process: true` and tell events
apart by their metadata. Pass `pid:` to deliver to a process other than the
caller.
