# Telemetry Events

This document describes the [`:telemetry`](https://hexdocs.pm/telemetry/)
events the kanban app emits, for operators who want to feed them into their
own monitoring and for developers who add new ones. Introduced by W2336, it
covers the foundation every later telemetry task builds on: one catalog of
events, one emit path that enforces it, and one test helper.

If you are setting up monitoring for the first time, read these first:

1. [Event reference](#event-reference) lists every event with its
   measurements, metadata and meaning.
2. [Privacy rule](#privacy-rule) says what event data never contains, and
   what your handler must not add.
3. [Attaching a handler](#attaching-a-handler) shows how to receive events.
4. [Metrics retention](#metrics-retention) says how long the app keeps the
   metrics it stores itself.

The sections in between explain individual event families in more detail.
The event reference is rendered from the catalog, and a test fails when the
two disagree (see [Adding an event](#adding-an-event)).

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
| `metrics` | The metrics generated for the event, as `{type, measurement}` pairs; see [Metrics](#metrics) |
| `persist` | Whether the event's first metric is stored in `metrics_events` |
| `tags` | Optional. The low-cardinality metadata keys its metrics are broken down by |

### Naming rule

A new event is named `[:kanban, domain, past_tense_action]`, for example
`[:kanban, :task, :archived]`. The domain is a singular noun (`:task`,
`:board`, `:user`, `:api`), and the action is a past-tense verb or verb phrase.
An irregular past tense counts, as in `[:kanban, :notification, :read]`,
`[:kanban, :digest, :sent]` and `[:kanban, :goal, :reassignment_undone]`, and
so does a past-tense verb followed by `to` and a destination, as in
`[:kanban, :goal, :promoted_to_ready]`.
A span prefix names the operation being timed, `[:kanban, domain, operation]`,
or `[:kanban, domain]` when the domain is itself the operation, as in
`[:kanban, :export]`. `:telemetry` appends `:start`, `:stop` and `:exception`
to it, so `[:kanban, :export]` emits `[:kanban, :export, :stop]` and
`[:kanban, :mcp, :request]` emits `[:kanban, :mcp, :request, :stop]`.

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

## Privacy rule

Event metadata never carries personal data, and carries free text only in the
two bounded cases listed below. An event carries row ids (`task_id`,
`user_id`, `board_id`), fixed labels (`reason`, `outcome`, `source`, `kind`),
field names and counts. It never carries an email address, an IP address, a
person's name, a title, a description, a comment, review notes, hook output or
a token.

Two kinds of metadata do carry text that the caller chose, so treat them as
untrusted input in your handler:

- **Request paths.** `path` on the `[:kanban, :api, ...]` task action events
  and on `[:kanban, :api, :auth_failed]` is the request path. `auth_failed`
  also fires for a request with no valid token, so a caller who is not signed
  in can choose part of that path, such as the task identifier in
  `/api/tasks/:id`.
- **`agent_name`** on `[:kanban, :audit, :completion_notes_credential_suspected]`
  and `[:kanban, :audit, :security_considerations_credential_suspected]` is the
  name the agent reported for itself, cut to 2,000 characters.

`endpoint` on `[:kanban, :api, :request]` and `[:kanban, :api, :error]` is not
caller-chosen, although both events also fire for a request with no valid
token. It is the template of the route the router matched, such as
`/api/tasks/:id/complete`, or the fixed string `unmatched` when the route
cannot be resolved. It is never built from the path the caller sent, so
`/api/mcp/`, `/api///mcp`, `/api/openapi%2Ejson` and a task identifier all
give one value. A request to a path with no route is rejected by the router
before either event fires, so it is not counted at all. `endpoint` is a
[tag](#tag-rule), so its set of values has to stay small. Rows stored before
this rule can still carry a raw path until
[retention](#metrics-retention) removes them.

The app enforces this in three places:

- **The catalog declares only safe keys.** A test fails if an entry declares a
  forbidden key (see [Metadata filtering](#metadata-filtering)).
- **The emit path drops anything else.** A forbidden key is removed before
  the event is sent, in every environment, and so is an undeclared key, except
  in [strict mode](#strict-mode), which is on only in tests and raises instead.
  Each removal is reported as `[:kanban, :telemetry, :metadata_dropped]` with
  the key names only.
- **Free text is replaced by a summary.** For example
  `[:kanban, :task, :unclaimed]` says whether a reason was given
  (`has_reason`), never the reason itself, and an email failure carries a
  bounded failure kind, never the mailer's reply.

The rule binds your handlers too. Do not add personal data or free text to
what you forward: do not look up a user's email or name from `user_id` and
attach it, do not forward the exception event's `reason` or `stacktrace`
verbatim (they are not filtered and can quote data from the failed operation),
and do not tag a metric by an id. Forward ids as ids, and resolve them inside
the app only when a person with access asks.

## Attaching a handler

Every event is a standard `:telemetry` event, so any handler attached with
`:telemetry.attach/4` or `:telemetry.attach_many/4` receives it. Pick the
events you need from the [Event reference](#event-reference), or read them at
runtime from `Kanban.Telemetry.Catalog.events/0`.

```elixir
defmodule MyMonitoring.StrideEvents do
  require Logger

  @events [
    [:kanban, :task, :claimed],
    [:kanban, :task, :completed],
    [:kanban, :rate_limit, :denied],
    [:kanban, :export, :stop]
  ]

  def attach do
    :telemetry.attach_many("my-monitoring-stride-events", @events, &__MODULE__.handle_event/4, nil)
  end

  def handle_event(event, measurements, metadata, _config) do
    Logger.info("stride event",
      event: Enum.join(event, "."),
      count: measurements[:count],
      board_id: metadata[:board_id]
    )
  end
end
```

Call `MyMonitoring.StrideEvents.attach/0` once at boot, for example from
`Kanban.Application.start/2` after the supervision tree has started.

- **Handlers run in the emitting process**, synchronously, inside the request,
  job or LiveView that emitted the event. Keep them fast: hand slow work, such
  as a network call to a monitoring service, to a separate process.
- **A handler that raises is detached** by `:telemetry` and receives nothing
  more until it is attached again. Rescue inside the handler if it can fail.
- **Use a handler id of your own**, unique across the app, so it never
  replaces one of the app's handlers.
- **For a span, attach to its `:stop` and `:exception` events.** Their
  `duration` measurement is in native time units; convert it with
  `System.convert_time_unit/3`. `[:kanban, :api, :request]` measures
  `duration` the same way.
- **Legacy names are stable.** An event marked legacy in the reference keeps
  its name, so a handler attached to it keeps working.
- **Watch `[:kanban, :telemetry, :metadata_dropped]`** to see when the app
  dropped a key from an event, for example after a code change.

The app's own consumers attach the same way: `KanbanWeb.Telemetry` builds its
metrics from the catalog (see [Metrics](#metrics)), and
`KanbanWeb.Telemetry.MetricsStorage` stores some of them.

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
| `[:kanban, :column, :deleted]` | `board_id`, `column_id`, `actor_user_id` | `Kanban.Columns.delete_column/2` |
| `[:kanban, :column, :reordered]` | `board_id`, `actor_user_id` | `Kanban.Columns.reorder_columns/3` |

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
- **Cascades emit nothing extra.** Deleting a board emits only `board.deleted`,
  not a `member_removed` per member, and deleting a column emits only
  `column.deleted`, not an event per task. Creating an AI-optimized board emits
  `[:kanban, :board, :creation]` and one `column.created` per default column.

### Export, rate-limit, MCP, GitHub and API auth events

W2343 added these. Two of them are spans: their `:start`, `:stop` and
`:exception` events measure how long the work took.

| Event | Kind | Metadata | Emitted by |
|---|---|---|---|
| `[:kanban, :export]` | span | `kind`, `format` | `Kanban.Archives.export_csv_for_board/1` and the metrics, workspace metrics, audit log and Organization audit log export controllers |
| `[:kanban, :rate_limit, :denied]` | event | `surface` | `Kanban.RateLimit.check/2` and `peek/2` |
| `[:kanban, :mcp, :request]` | span | `method`, `outcome` | `KanbanWeb.MCP.Server` |
| `[:kanban, :github, :issue_created]` | event | `outcome`, `reason` | `Kanban.GitHub.create_issue/3` |
| `[:kanban, :api, :auth_failed]` | event | `reason`, `path`, `method` | `KanbanWeb.Plugs.AuthenticateApiToken` |

- **Exports.** `kind` is `:archive_csv` (board archive CSV), `:metrics_pdf`
  (board metrics report), `:workspace_metrics` (workspace metrics report),
  `:audit_log` (site-admin audit log) or `:org_audit_log` (an org-admin's
  Organization audit log). `format` is `:csv`, `:pdf`, `:xlsx` or `:json`. The stop event
  also measures `row_count` for `:archive_csv`, the number of archived tasks
  exported; the other exports have no row count to report. A board, its
  name, the metric filters and the audit-log filters never appear, nor the
  admin's or org-admin's IP address. A failed metrics report that redirects with an error
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
  the GitHub integration is not configured counts as `:error`. `reason` says
  why: `:none` on success, `:not_configured` when the token or repo is
  missing, `:http_error` when GitHub answers with anything but a 201 carrying
  an issue URL, and `:transport_error` when the request never got an answer.
  It is a fixed atom chosen in `Kanban.GitHub`, never the response body or
  the HTTP client's error, and it is a metric tag alongside `outcome`. The
  title, body, labels, issue URL and error text are never emitted.
- **`missing_token`** is a new `reason` for `[:kanban, :api, :auth_failed]`,
  sent when an API request has no `Authorization` header or one that is not a
  `Bearer` header. The other reasons are `rate_limited`, `token_not_found`,
  `token_revoked`, `token_expired` and `user_disabled`. Unlike most reasons
  in the catalog, these are strings, not atoms. The audit copy,
  `[:kanban, :audit, :api_token_auth_failed]`, carries the token lookup's own
  atoms instead (`:missing_token`, `:not_found`, `:revoked`, `:expired` and
  `:user_disabled`), and a rate-limited request writes no audit row.

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
- **An approval's events report only a committed approval.** The approval
  completes the task inside `Kanban.Reviews`' transaction, so
  `task.completed` is held back with the goal events by
  `Kanban.Telemetry.AfterCommit.after_commit/1`, emitted only once the review
  has committed, and dropped if it rolls back or is refused. Its handler never
  runs inside that transaction. After the commit the events arrive in a fixed
  order: `task.completed` first, then the events the completion caused in the
  order it caused them (`goal.grace_window_scheduled` when the task was its
  goal's last child, `task.unblocked` for each dependent it unblocked, then
  `goal.completed`), and last `review_approved`. A rolled-back or refused
  approval emits none of them.
  An API completion, `mark_done` and an API `mark_reviewed` run no
  transaction of their own around it, so they still emit `task.completed`
  straight away, once. Only that review transaction is waited for: were
  `approve_review/3` itself called inside an outer transaction, the events
  would be emitted when the review's own transaction returned, before the
  outer one committed. Nothing calls it that way today.
- **`comment_created` never carries the comment text.** `user_id` is the
  author and `by_agent` is `true` when an agent wrote it.
- **Not covered.** Bulk moves, assignments and labels from
  `Kanban.Tasks.BulkActions`, automatic goal repositioning, the automatic
  deletion of an empty parent goal, the sibling position shifts after a
  delete, cascaded children, and comment edits and deletions emit none of
  these events.

### User, session and administrator events

W2338 added these. They are declared in
`Kanban.Telemetry.Catalog.UserEvents` (`lib/kanban/telemetry/catalog/user_events.ex`).
The account and administrator events are emitted by
`Kanban.Accounts.UserTelemetry`, and the two session events by
`KanbanWeb.UserAuth`, next to the legacy `[:kanban, :user, :login]`. Each is
emitted only after its change has been saved, so a refused, invalid or
rolled-back change emits nothing. Every event measures `count: 1`, except
`sessions_revoked`, whose `count` is the number of tokens revoked.

| Event | Metadata | Emitted by |
|---|---|---|
| `[:kanban, :user, :logged_out]` | `user_id` | `KanbanWeb.UserAuth.log_out_user/1` |
| `[:kanban, :user, :sessions_revoked]` | `user_id` | `KanbanWeb.UserAuth.disconnect_sessions/1` |
| `[:kanban, :user, :password_changed]` | `user_id` | `Kanban.Accounts.update_user_password/2` |
| `[:kanban, :user, :password_reset_completed]` | `user_id` | `Kanban.Accounts.reset_user_password/2` |
| `[:kanban, :user, :email_change_requested]` | `user_id` | `Kanban.Accounts.deliver_user_update_email_instructions/3` |
| `[:kanban, :user, :email_changed]` | `user_id` | `Kanban.Accounts.update_user_email/2` |
| `[:kanban, :user, :confirmed]` | `user_id` | `Kanban.Accounts.confirm_user/1` |
| `[:kanban, :user, :name_changed]` | `user_id` | `Kanban.Accounts.update_user_name/2` |
| `[:kanban, :user, :type_changed]` | `user_id`, `from_type`, `to_type` | `Kanban.Accounts.update_user_type/2` |
| `[:kanban, :user, :disabled]` | `user_id`, `actor_user_id` | `Kanban.Accounts.disable_user/2` |
| `[:kanban, :user, :enabled]` | `user_id`, `actor_user_id` | `Kanban.Accounts.enable_user/2` |
| `[:kanban, :user, :deleted]` | `user_id`, `actor_user_id` | `Kanban.Accounts.delete_user/2` |

- **Ids and user types only.** No event carries an email address (old or
  new), a name, a password or a token value. The two email events carry only
  `user_id`.
- **A save that changes nothing emits nothing.** `name_changed` needs a new
  name and `type_changed` a new type. `disabled` fires only for an enabled
  user and `enabled` only for a disabled one, so disabling a disabled user
  again emits nothing.
- **Administrator actions carry `actor_user_id`.** `disabled`, `enabled` and
  `deleted` name the administrator. `type_changed` carries no
  `actor_user_id`, because `update_user_type/2` is not given one. Outside the
  tests, the only caller under `lib/` is a mix task.
- **`logged_out` without a session.** Signing out when nobody is signed in
  still emits `logged_out`, without a `user_id`.
- **`sessions_revoked` counts every token.** A password change or reset
  deletes all of the user's tokens (sessions and outstanding email links) and
  then disconnects them; `count` is that number and may be 0. `user_id` is
  left out when no token names a user.
- **Account deletions are audited.** `delete_user/2` also records the
  `:user_deleted` audit event on success and `:user_delete_refused` on every
  refusal, whose `reason` is `unauthorized`, `cannot_delete_self`,
  `user_has_boards`, `last_admin` or `personal_workspace_has_boards`. Each
  carries the acting user as `user_id` and the target account as
  `member_user_id`, ids only. Both are written after the deletion's
  transaction returns, so a rollback cannot erase a refusal.
  `[:kanban, :user, :deleted]` itself still fires only on success.
- **Not covered.** Login failures are already recorded by the audit log, and
  no audit row is added for disabling or enabling a user.

### Notification, email delivery, digest, delivery target and message events

W2342 added these. They are declared in three catalog modules:
`Kanban.Telemetry.Catalog.NotificationEvents`
(`lib/kanban/telemetry/catalog/notification_events.ex`) for notifications,
email delivery and the weekly digest, `Kanban.Telemetry.Catalog.TargetEvents`
(`lib/kanban/telemetry/catalog/target_events.ex`) for delivery targets, and
`Kanban.Telemetry.Catalog.MessageEvents`
(`lib/kanban/telemetry/catalog/message_events.ex`) for admin broadcast
messages. They are emitted by `Kanban.Notifications.NotificationTelemetry`,
`Kanban.Targets.TargetTelemetry` and `Kanban.Messages.MessageTelemetry`, each
only after its change has been saved, or after the mailer has answered, so a
refused or invalid change emits nothing. Every event measures `count: 1`,
except `all_read` and `fanout_completed`, whose `count` is the number of
notifications marked read or digest recipients, and may be 0.

| Event | Metadata | Emitted by |
|---|---|---|
| `[:kanban, :notification, :created]` | `notification_id`, `user_id`, `event_type`, `board_id`, `in_app` | `Kanban.Notifications.notify/3`, once per saved row |
| `[:kanban, :notification, :read]` | `notification_id`, `user_id`, `event_type` | `Kanban.Notifications.mark_read/2` |
| `[:kanban, :notification, :all_read]` | `user_id` | `Kanban.Notifications.mark_all_read/1` |
| `[:kanban, :notification, :preference_updated]` | `user_id`, `event_type`, `in_app`, `mail` | `Kanban.Notifications.update_preference/3` |
| `[:kanban, :notification, :unsubscribed]` | `user_id`, `event_type` | `Kanban.Notifications.unsubscribe/2` |
| `[:kanban, :notification, :email_sent]` | `notification_id`, `user_id`, `event_type` | `Kanban.Notifications.EmailWorker` |
| `[:kanban, :notification, :email_skipped]` | `notification_id`, `reason` | `Kanban.Notifications.EmailWorker` |
| `[:kanban, :notification, :email_failed]` | `notification_id`, `user_id`, `event_type`, `error` | `Kanban.Notifications.EmailWorker` |
| `[:kanban, :digest, :sent]` | `user_id`, `week` | `Kanban.Notifications.DigestWorker` |
| `[:kanban, :digest, :fanout_completed]` | `week` | `Kanban.Notifications.DigestFanoutWorker` |
| `[:kanban, :target, :created]` | `target_id`, `actor_user_id` | `Kanban.Targets.create_target/2` |
| `[:kanban, :target, :updated]` | `target_id`, `actor_user_id`, `fields` | `Kanban.Targets.update_target/3` |
| `[:kanban, :target, :archived]` | `target_id`, `actor_user_id` | `Kanban.Targets.archive_target/2` |
| `[:kanban, :target, :unarchived]` | `target_id`, `actor_user_id` | `Kanban.Targets.unarchive_target/2` |
| `[:kanban, :target, :goal_assigned]` | `target_id`, `goal_id`, `board_id`, `actor_user_id` | `Kanban.Targets.assign_goal/3` |
| `[:kanban, :target, :goal_unassigned]` | `target_id`, `goal_id`, `board_id`, `actor_user_id` | `Kanban.Targets.unassign_goal/2` |
| `[:kanban, :target, :status_changed]` | `target_id`, `from_status`, `to_status` | `Kanban.Targets.record_observed_status/3` |
| `[:kanban, :message, :created]` | `message_id`, `sender_user_id` | `Kanban.Messages.create_message/2` |
| `[:kanban, :message, :deleted]` | `message_id`, `sender_user_id` | `Kanban.Messages.delete_message/1` |
| `[:kanban, :message, :dismissed]` | `message_id`, `user_id` | `Kanban.Messages.dismiss_message/2` |

- **Ids, event types and counts only.** No event carries an email address, a
  notification's title or body, a message's title or body, a target's name or
  description, or a raw mailer error. `mail` is the saved email flag of a
  preference, a boolean.
- **Email delivery has three outcomes.** `email_sent` fires once the mailer
  has accepted the email. `email_skipped` fires when the job sends nothing,
  with `reason` `:not_found`, `:already_emailed`, `:user_disabled`,
  `:user_unconfirmed`, `:not_a_member` or `:unsubscribed`. The job reads the
  recipient's email preference again before sending, so turning email off
  after a job was queued skips it with `:unsubscribed`. `email_failed` fires
  once per failed attempt, so a job Oban retries can emit it more than once;
  `error` is the bounded failure kind from `EmailWorker.failure_kind/1`,
  because SMTP replies often echo the recipient address.
- **A save that changes nothing emits nothing.** `read` needs an unread
  notification, `preference_updated` a changed flag, `updated` a changed field
  (`fields` lists the names, never the values), `archived` an active target,
  `unarchived` an archived one, `goal_assigned` a new target for the goal,
  `goal_unassigned` a goal that had one, and `dismissed` a first dismissal.
- **`status_changed` fires only on a change.** The hourly sweep records a
  target's status only when it differs from the stored watermark, and the
  event fires only when that write lands, including a silent move back to
  `:on_track` or `:complete`. `from_status` is `nil` on the first
  observation. A stale write from an overlapping sweep emits nothing.
- **An unsubscribe link emits two events.** It saves the preference through
  `update_preference/3`, so `preference_updated` fires when email was on, and
  `unsubscribed` fires every time the link is used. `user_id` comes from the
  verified link.
- **Delivery targets have no board.** A target spans boards, so only
  `goal_assigned` and `goal_unassigned` carry a `board_id`, the goal's.
  Creating, editing and archiving are owner-only, so `actor_user_id` is the
  owner.
- **`created` follows `notify/3`'s own transaction.** `notify/3` is meant to
  be called after the change that triggers it has committed; a caller that
  runs it inside an outer transaction that later rolls back will already have
  emitted `created`.
- **Not covered.** A recipient whose email preference is already off when
  the notification is created gets no email job, so no email event fires for
  them. Digest skips and digest delivery failures emit no event. The status
  sweep emits no event of its own for the owner notification it sends beyond
  `target.status_changed`; that notification reports through
  `notification.created` and the email events like any other.

### Goal, dependency and after_goal events

W2341 added these. They are declared in
`Kanban.Telemetry.Catalog.GoalEvents` (`lib/kanban/telemetry/catalog/goal_events.ex`)
and emitted by `Kanban.Tasks.GoalTelemetry`. Each is emitted only after its
change has committed, so a refused, invalid or rolled-back change emits
nothing. Every event measures `count: 1`.

| Event | Metadata | Emitted by |
|---|---|---|
| `[:kanban, :task, :unblocked]` | `task_id`, `board_id` | `Kanban.Tasks.Dependencies.unblock_dependent_tasks/2`, once per dependent that is no longer blocked |
| `[:kanban, :goal, :completed]` | `goal_id`, `board_id` | `Kanban.Tasks.AgentWorkflow` (API completion, `mark_reviewed` and approvals in the review queue), from the id `Kanban.Tasks.GoalCompletion.finalize_child/2` returns |
| `[:kanban, :goal, :promoted_to_ready]` | `goal_id`, `board_id` | `Kanban.Tasks.Goals.promote_goal_to_ready/2`; also measures `task_count` |
| `[:kanban, :goal, :after_goal_succeeded]` | `goal_id`, `board_id`, `source` | `Kanban.Tasks.Goals.mark_after_goal_succeeded_and_promote/2`; also measures `duration_ms` for an agent report |
| `[:kanban, :goal, :after_goal_failed]` | `goal_id`, `board_id`, `exit_code` | `Kanban.Tasks.Goals.record_after_goal_failure/2`; also measures `duration_ms` |
| `[:kanban, :goal, :grace_window_scheduled]` | `goal_id`, `board_id` | `Kanban.AfterGoal.schedule_grace_window/1`; also measures `grace_window_ms` |
| `[:kanban, :goal, :grace_window_expired]` | `goal_id`, `board_id` | `Kanban.Tasks.Goals.mark_after_goal_succeeded_and_promote/2`, when `Kanban.AfterGoal.GraceWorker` moves a pending goal to Done |
| `[:kanban, :goal, :reassigned]` | `goal_id`, `board_id`, `actor_user_id`, `assigned_to_id` | `Kanban.Tasks.Interventions.reassign_goal_unstarted/3` |
| `[:kanban, :goal, :reprioritized]` | `goal_id`, `board_id`, `actor_user_id`, `priority` | `Kanban.Tasks.Interventions.reprioritize_goal_unstarted/3` |
| `[:kanban, :goal, :reassignment_undone]` | `goal_id`, `board_id`, `actor_user_id` | `Kanban.Tasks.Interventions.undo_reassignment/3` |
| `[:kanban, :goal, :reprioritization_undone]` | `goal_id`, `board_id`, `actor_user_id` | `Kanban.Tasks.Interventions.undo_reprioritization/3` |

- **`goal.completed` fires once per goal, after the commit.** It fires when a
  completion of the goal's last child first moves the goal's
  `after_goal_status` from `nil` to `:pending`, a change that happens at most
  once per goal, so a re-opened and re-completed child does not fire it again.
  The agent workflow emits it after its own transaction commits. An approval
  in the review queue runs that workflow inside `Kanban.Reviews`' transaction,
  which wraps it in `Kanban.Telemetry.AfterCommit.after_commit/1` (also
  reachable as `GoalTelemetry.after_commit/1`): `goal.completed`,
  `task.unblocked`, `grace_window_scheduled` and the child's `task.completed`
  are held back and emitted only once the review has committed, and dropped
  if it rolls back. Outside
  that wrapper, `goal.completed` is never emitted while a transaction is
  open. An API completion of the last child therefore emits both
  `task.completed` and `goal.completed`. The goal itself reaches Done later,
  which `after_goal_succeeded` reports.
- **after_goal output is never sent.** A project's after_goal hook can print
  anything, including secrets. `after_goal_failed` carries only the exit code
  (`nil` when it is not an integer) and the reported `duration_ms`.
  `after_goal_succeeded` has `source` `:agent` for an agent report, measuring
  its `duration_ms` when it is an integer, or `:grace_worker` when the grace
  window expired. A duplicate report for a goal already in Done emits nothing.
- **A dependent that is still blocked emits nothing.** `task.unblocked` fires
  only for a dependent whose last incomplete dependency was just completed.
- **`promoted_to_ready` needs a move.** It fires only when at least one task
  moved to Ready, and `task_count` counts them, the goal included.
- **`grace_window_expired` fires only when the worker promotes the goal.** It
  is emitted beside the worker's `after_goal_succeeded`, so a goal the agent
  already reported on, or one that is missing, emits nothing, and neither
  does a worker run that loses the race to an agent report.
- **Intervention counts leave out the goal.** `moved_count` counts the
  children changed or restored and `skipped_count` the claimed children (or,
  for an undo, the children that could no longer be restored).
  `actor_user_id` is the user who intervened.
- **Not covered.** A goal whose last child is dragged into Done on the board,
  or completed through the deprecated `mark_done/2`, emits no
  `goal.completed`. Recomputing a task's blocking status after its
  dependencies are edited emits no `task.unblocked`.

### Organization events

W2390 added `created` and `updated`, W2391 added `member_added` and
`member_removed`, W2392 added `account_created` to `member_added`, and W2396
added the three workspace events. They are declared in
`Kanban.Telemetry.Catalog.OrganizationEvents` (`lib/kanban/telemetry/catalog/organization_events.ex`)
and emitted by `Kanban.Organizations.OrganizationTelemetry`. Each is emitted
only after its change has committed, so a refused, invalid or rolled-back
change emits nothing. Every event measures `count: 1`.

| Event | Metadata | Emitted by |
|---|---|---|
| `[:kanban, :organization, :created]` | `organization_id`, `actor_user_id` | `Kanban.Organizations.create_organization/2` |
| `[:kanban, :organization, :updated]` | `organization_id`, `actor_user_id`, `fields` | `Kanban.Organizations.update_organization/3`, only when at least one field changed |
| `[:kanban, :organization, :member_added]` | `organization_id`, `user_id`, `role`, `actor_user_id`, `account_created` | `Kanban.Organizations.add_member/3`, `appoint_org_admin/3` and `appoint_org_admin_by_email/4`, only when a membership was created |
| `[:kanban, :organization, :member_removed]` | `organization_id`, `user_id`, `role`, `actor_user_id` | `Kanban.Organizations.remove_org_admin/3` |
| `[:kanban, :organization, :workspace_created]` | `organization_id`, `workspace_id` | `Kanban.Organizations.OrgWorkspaces.create_workspace/3` |
| `[:kanban, :organization, :workspace_renamed]` | `organization_id`, `workspace_id` | `Kanban.Organizations.OrgWorkspaces.rename_workspace/3`, only when the name changed |
| `[:kanban, :organization, :workspace_archived]` | `organization_id`, `workspace_id` | `Kanban.Organizations.OrgWorkspaces.archive_workspace/2`, once the archive has committed |

- **Who causes them.** Only an enabled site admin creates or edits an
  Organization, or appoints or removes an org-admin, and `actor_user_id` is
  that site admin. `add_member/3` is the internal function invitation
  acceptance calls; its `actor_user_id` is the joining user.
- **`member_added` reports new memberships only.** Promoting a member to
  org-admin, or adding someone who is already in the Organization, emits no
  `member_added`; a promotion is recorded by the `:org_admin_appointed` audit
  event below. `user_id` is the member and `role` is `:member` or
  `:org_admin`; on `member_removed` it is the role the member held.
- **They can wait for an outer commit.** The membership events go through
  `Kanban.Telemetry.AfterCommit.defer/2`, so a caller that wraps its own
  transaction in `Kanban.Telemetry.AfterCommit.after_commit/1` holds them,
  and their audit rows, until that transaction commits.
- **No personal data.** An Organization's name, address and contact name,
  phone and email never appear in the metadata. `fields` lists the changed
  field names, never their values.
- **Audit events.** `:organization_created` and `:organization_updated` go
  through `Kanban.AuditLog.event/2` with `organization_id`, and the site admin
  as `user_id`. Appointing a new or promoted org-admin records
  `:org_admin_appointed`, and removing one records `:org_admin_removed`, each
  with `organization_id`, the site admin as `user_id` and the org-admin as
  `member_user_id`. `:org_admin_appointed` also carries `account_created`.
  An org-admin downloading their Organization's audit log records
  `:org_audit_log_exported` with `organization_id` and the org-admin as
  `user_id`. An audit event whose `organization_id` is a positive integer
  naming an existing Organization also stores it in the
  `audit_events.organization_id` column, which scopes the org-admin audit log
  at `/org/audit`; an out-of-range or stale id stays in the metadata only.
- **`account_created` marks a provisioned account.** It is `true` on
  `member_added` and `:org_admin_appointed` only when
  `appoint_org_admin_by_email/4` created the appointee's account in the same
  transaction, and `false` otherwise, including every `add_member/3` join.
  The registration event, `member_added` and the audit row for a provisioned
  account wait for that transaction to commit; neither the event nor the
  audit row carries the password or a token.
- **Workspace events.** An org-admin creating, renaming or archiving one of
  their Organization's workspaces in the org console emits the matching
  `workspace_*` event and records `:org_workspace_created`,
  `:org_workspace_renamed` or `:org_workspace_archived` with
  `organization_id`, `workspace_id` and the org-admin as `user_id`. The
  telemetry events carry the two ids only; the workspace name is never in
  either. A refused change (not an org-admin, a workspace outside the
  Organization, a personal or archived workspace, or an archive refused while
  the workspace holds boards) and an invalid name emit and record nothing.

### Plan events

W2399 added the paid-plan refusal event. It is declared in
`Kanban.Telemetry.Catalog.PlanEvents` (`lib/kanban/telemetry/catalog/plan_events.ex`)
and emitted by `Kanban.Plans`. It measures `count: 1`.

| Event | Metadata | Emitted by |
|---|---|---|
| `[:kanban, :plan, :feature_refused]` | `feature`, `surface` | `Kanban.Plans.check_board/3` and `check_user/3`, only when they refuse |

- **When it fires.** Only when plans are enforced and the board or user is
  on the free plan, so nothing is emitted while `:plans_enforced` is off. An
  allowed check emits nothing.
- **What it carries.** `feature` is one of `Kanban.Plans.features/0`
  (`:notifications`, `:audit`, `:sso`, `:workspaces`, `:bulk_actions`,
  `:integrations`, `:telemetry` or `:mcp`) and `surface` is the entry point
  that refused it: `:live_view`, `:controller`, `:rest`, `:mcp`, `:oban` or
  `:context`. Both are tags. The board, the user and the request are never
  sent.
- **A bad label raises instead.** A feature or surface outside those sets
  raises `ArgumentError` in `Kanban.Plans` before anything is emitted, with
  enforcement on or off, so an unknown value never reaches a handler.
- **Not persisted.** A free user can trigger a refusal at will, so the event
  is charted but never stored in `metrics_events`.

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
   following the naming rule and declaring no forbidden key. Choose its
   `metrics` and `persist` as described in [Metrics](#metrics). A
   board, membership or column event is an entry in
   `Kanban.Telemetry.Catalog.BoardEvents`. A new API or
   audit action is a new tuple in `@api_actions` or `@audit_actions` in
   `Kanban.Telemetry.Catalog.Families`, a new task activity event is an
   entry in `Kanban.Telemetry.Catalog.TaskEvents`, a new account, session or
   user administration event is an entry in
   `Kanban.Telemetry.Catalog.UserEvents`, a new notification, email delivery
   or digest event is an entry in
   `Kanban.Telemetry.Catalog.NotificationEvents`, a new delivery target event
   is an entry in `Kanban.Telemetry.Catalog.TargetEvents`, a new broadcast
   message event is an entry in `Kanban.Telemetry.Catalog.MessageEvents`, a
   new goal, dependency or after_goal event is an entry in
   `Kanban.Telemetry.Catalog.GoalEvents`, a new Organization event is an
   entry in `Kanban.Telemetry.Catalog.OrganizationEvents`, and a new paid
   plan event is an entry in `Kanban.Telemetry.Catalog.PlanEvents`.
2. Emit it with `Kanban.Telemetry.emit/3` or `Kanban.Telemetry.span/3`.
3. Test it with the helper below. `test/kanban/telemetry_test.exs` fails if an
   entry is missing a field, repeats a name, declares a forbidden key, or has
   invalid metrics or tags, and `test/kanban_web/telemetry_test.exs` fails if
   an event has no metric.
4. Refresh the [Event reference](#event-reference). Render it from the
   catalog and paste the output between its two marker comments:

   ```bash
   MIX_ENV=test mix run --no-start -e 'IO.write(Kanban.TelemetryDoc.reference())'
   ```

   `test/kanban/telemetry_docs_test.exs` fails until you do. It also fails
   when this doc names an event the catalog lacks, anywhere in the file, or
   when a table here lists metadata keys that differ from the catalog entry's.
   `Kanban.TelemetryDoc` (`test/support/telemetry_doc.ex`) holds the renderer
   and the parsers the test uses.

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

## Metrics

Since W2344 `KanbanWeb.Telemetry.metrics/0`, which LiveDashboard charts at
`/admin/dashboard` and `KanbanWeb.Telemetry.MetricsStorage` stores from, builds
its application metrics from the catalog. `KanbanWeb.Telemetry.CatalogMetrics`
(`lib/kanban_web/telemetry/catalog_metrics.ex`) turns each `{type, measurement}`
pair in an entry's `metrics` into one metric, so a new event cannot be left
without one:

| Entry | Metric name | Example |
|---|---|---|
| An event, `[counter: :count]` | The event name plus the measurement | `kanban.api.task_claimed.count` |
| An event, `[sum: :count]` | The event name plus the measurement | `kanban.board.creation.count` |
| An event, `[summary: :duration]` | The event name plus the measurement, in milliseconds | `kanban.api.request.duration` |
| A span, `[summary: :duration]` | The `:stop` event name plus the measurement, in milliseconds | `kanban.export.stop.duration` |

Most events take `[counter: :count]`. Use `:sum` when `count` is a number of
things rather than 1, as for `token_bulk_revoked`, `sessions_revoked`,
`notification.all_read` and `digest.fanout_completed`, and give every span
`[summary: :duration]` first. The entry's description becomes the metric's
description, and its `tags` become the metric's tags.

Every metric name that existed before W2344 kept its name, type and tags,
because the stored history and the admin users page read them. A test in
`test/kanban_web/telemetry_test.exs` lists them.

### Which metrics are stored

`MetricsStorage` stores one row per event in `metrics_events` for an entry
whose `persist` is `true`, and only its first metric: it attaches one handler
per event. A new event should be stored only when it is rare enough not to
flood the table and unauthenticated traffic cannot trigger it at will.

Stored today:

- everything that was stored before W2344 except
  `phoenix.socket_connected.duration` (see below), which keeps its history:
  sign-ups, sign-ins, board creation, the API task actions below, after_goal
  delivery in a `/complete` or `/mark_reviewed` response, the review panel
  counters, the API request and error counts, and the Phoenix socket and
  channel metrics (`phoenix.socket_drain.count`,
  `phoenix.channel_joined.duration` and `phoenix.channel_handled_in.duration`),
  which carry no `persist: false`;
- since W2344, export, the GitHub issue report, the metrics retention run,
  `after_goal` success and failure, failed notification email and the digest
  fan-out.

The API request and error counts are the exception to the rule for new
events. `KanbanWeb.Plugs.ApiTelemetry` runs before the API token is checked,
and on the public API routes with no token at all, so any request to an `/api`
route, signed in or not, stores a `kanban.api.request.count` row and, for a
status of 400 or above, a `kanban.api.error.count` row. They stay stored
because their history predates W2344; the daily retention job bounds them.

Only the API task actions that were stored before W2344 are stored:
`task_claimed`, `task_completed`, `task_created`, `task_unclaimed`,
`task_marked_done` and `task_returned_to_doing`, plus `next_task_fetched`.
`Kanban.Metrics.UserActivity` counts every stored `kanban.api.task_*` row as
admin activity, so storing another one, such as `task_listed`, would change
those counts.

These are never stored, whatever their options say:

- VM metrics, and `kanban.repo.query`, `phoenix.endpoint` and
  `phoenix.router_dispatch`, which fire on every query or request;
- LiveView mount and `handle_event`, Oban job, and `kanban.pubsub` metrics,
  which fire on every page load, click, job or change;
- `phoenix.socket_connected.duration`, which fires on every WebSocket
  connect, so on every LiveView page load and reconnect, and whose metadata
  carries the connection's `connect_info`. It stays registered for
  LiveDashboard under the same name, but it is not stored, and the rows stored
  before it was excluded are left to the retention job;
- Swoosh metrics, whose metadata carries the email and the mailer config.

`MetricsStorage.metrics_history/1` returns no history for a metric it never
stores, without querying.

### Framework metrics

`KanbanWeb.Telemetry` also defines these, all shown live only:

| Metric | Tags |
|---|---|
| `phoenix.live_view.mount.stop.duration` | `view` |
| `phoenix.live_view.handle_event.stop.duration` | `view` |
| `oban.job.stop.duration` | `worker`, `queue` |
| `oban.job.exception.duration` | `worker`, `queue` |
| `swoosh.deliver.stop.duration` | `mailer` |
| `swoosh.deliver.exception.duration` | `mailer` |

The LiveView event name is not a tag, because the browser sends it. A Swoosh
delivery that returns an error still ends in `:stop`; `:exception` is a raise.

### Tag rule

A tag becomes a LiveDashboard label, so it must be a metadata key with a small,
fixed set of values that says nothing about a person: `endpoint`, `method`,
`status`, `kind`, `format`, `outcome`, `surface`, `reason` or `feature`. Never tag by
`user_id`, `board_id`, `task_id` or any other id.
`test/kanban/telemetry_test.exs` fails if an entry tags any other key.

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

## Event reference

Every event in `Kanban.Telemetry.Catalog`, grouped by domain, the second
segment of its name. This list is rendered from the catalog, so it is complete;
the sections above explain which code emits each family and when.

- **Kind** is `event` for a single event or `span` for a span prefix. A span
  emits three events, named by the prefix plus `:start`, `:stop` and
  `:exception`, as listed below its table. `event, legacy` marks an event
  whose name predates the catalog and may break the
  [naming rule](#naming-rule); it keeps its name, so it is safe to rely on.
- **Measurements** are the numbers the event carries. `count` is 1 unless the
  description says otherwise.
- **Metadata** are the keys the event may carry; a key can be absent from a
  single event, for example when its value is unknown. The
  [privacy rule](#privacy-rule) applies to every one of them.

<!-- event-reference:start -->
### Domain `api`

| Event | Kind | Measurements | Metadata | Description |
|---|---|---|---|---|
| `[:kanban, :api, :token_created]` | event, legacy | `count` | `user_id`, `board_id`, `token_id` | An API token was created. |
| `[:kanban, :api, :token_revoked]` | event, legacy | `count` | `user_id`, `token_id` | An API token was revoked. |
| `[:kanban, :api, :token_deleted]` | event, legacy | `count` | `user_id`, `token_id` | An API token was deleted. |
| `[:kanban, :api, :token_used]` | event, legacy | `count` | `user_id`, `token_id` | An API token authenticated a request. |
| `[:kanban, :api, :request]` | event, legacy | `count`, `duration` | `endpoint`, `method`, `status` | An API request finished. Duration is in native time units. |
| `[:kanban, :api, :error]` | event, legacy | `count` | `endpoint`, `status`, `method` | An API request finished with a status of 400 or above. |
| `[:kanban, :api, :auth_failed]` | event, legacy | `count` | `reason`, `path`, `method` | An API request failed bearer-token authentication. |
| `[:kanban, :api, :after_goal_delivered]` | event, legacy | `count` | `goal_id`, `board_id`, `project_id` | An after_goal hook was included in a /complete or /mark_reviewed response. |
| `[:kanban, :api, :token_bulk_revoked]` | event | `count` | `board_id`, `user_id`, `actor_user_id`, `reason` | A member's API tokens for a board were revoked because they were removed (reason :member_removed) or set to read_only (:read_only_access). count is the number revoked and may be 0. |
| `[:kanban, :api, :next_task_fetched]` | event, legacy | `count` | `task_id`, `priority`, `board_id`, `user_id`, `path`, `method` | An agent fetched its next task. |
| `[:kanban, :api, :task_claimed]` | event, legacy | `count` | `task_id`, `priority`, `api_token_id`, `specific_task`, `board_id`, `user_id`, `path`, `method` | An agent claimed a task. |
| `[:kanban, :api, :task_completed]` | event, legacy | `count` | `task_id`, `time_spent_minutes`, `board_id`, `user_id`, `path`, `method` | An agent completed a task. |
| `[:kanban, :api, :task_listed]` | event, legacy | `count` | `count`, `board_id`, `user_id`, `path`, `method` | An agent listed tasks. |
| `[:kanban, :api, :comments_listed]` | event, legacy | `count` | `task_id`, `count`, `board_id`, `user_id`, `path`, `method` | An agent listed a task's comments. |
| `[:kanban, :api, :comment_created]` | event, legacy | `count` | `task_id`, `board_id`, `user_id`, `path`, `method` | An agent added a comment to a task. |
| `[:kanban, :api, :task_created]` | event, legacy | `count` | `task_id`, `board_id`, `user_id`, `path`, `method` | An agent created a task. |
| `[:kanban, :api, :goal_created]` | event, legacy | `count` | `goal_id`, `child_task_count`, `batch`, `batch_index`, `board_id`, `user_id`, `path`, `method` | An agent created a goal with its child tasks. |
| `[:kanban, :api, :batch_goals_created]` | event, legacy | `count` | `total_goals`, `board_id`, `user_id`, `path`, `method` | An agent created goals in one batch. |
| `[:kanban, :api, :task_create_forbidden_fields_filtered]` | event, legacy | `count` | `goal_fields`, `child_fields`, `board_id`, `user_id`, `path`, `method` | Fields an agent may not set were dropped from a create request. |
| `[:kanban, :api, :task_updated]` | event, legacy | `count` | `task_id`, `board_id`, `user_id`, `path`, `method` | An agent updated a task. |
| `[:kanban, :api, :task_update_column_change_forbidden]` | event, legacy | `count` | `task_id`, `board_id`, `user_id`, `path`, `method` | An agent tried to move a task to another column with an update. |
| `[:kanban, :api, :task_update_forbidden_fields_filtered]` | event, legacy | `count` | `task_id`, `fields`, `board_id`, `user_id`, `path`, `method` | Fields an agent may not set were dropped from an update request. |
| `[:kanban, :api, :task_unclaimed]` | event, legacy | `count` | `task_id`, `board_id`, `user_id`, `path`, `method` | An agent released a claimed task. |
| `[:kanban, :api, :task_marked_done]` | event, legacy | `count` | `task_id`, `review_status`, `board_id`, `user_id`, `path`, `method` | A reviewed task was marked done. |
| `[:kanban, :api, :task_returned_to_doing]` | event, legacy | `count` | `task_id`, `review_status`, `board_id`, `user_id`, `path`, `method` | A reviewed task was sent back to Doing. |
| `[:kanban, :api, :after_goal_reported]` | event, legacy | `count` | `task_id`, `exit_code`, `board_id`, `user_id`, `path`, `method` | An agent reported its after_goal result. |
| `[:kanban, :api, :task_changed_files_persisted]` | event, legacy | `count` | `task_id`, `file_count`, `board_id`, `user_id`, `path`, `method` | An agent's changed files were stored on a task. |
| `[:kanban, :api, :dependencies_fetched]` | event, legacy | `count` | `task_id`, `board_id`, `user_id`, `path`, `method` | An agent fetched a task's dependencies. |
| `[:kanban, :api, :dependents_fetched]` | event, legacy | `count` | `task_id`, `count`, `board_id`, `user_id`, `path`, `method` | An agent fetched a task's dependents. |
| `[:kanban, :api, :task_tree_fetched]` | event, legacy | `count` | `task_id`, `board_id`, `user_id`, `path`, `method` | An agent fetched a task tree. |
| `[:kanban, :api, :after_goal_status_fetched]` | event, legacy | `count` | `task_id`, `board_id`, `user_id`, `path`, `method` | An agent fetched a goal's after_goal status. |
| `[:kanban, :api, :mcp_tool_called]` | event, legacy | `count` | `tool`, `is_error`, `board_id`, `user_id`, `path`, `method` | An agent called an MCP tool. |

### Domain `audit`

| Event | Kind | Measurements | Metadata | Description |
|---|---|---|---|---|
| `[:kanban, :audit, :login_failed]` | event, legacy | `count` | none | A browser sign-in failed. |
| `[:kanban, :audit, :password_reset_requested]` | event, legacy | `count` | none | A password reset was requested. |
| `[:kanban, :audit, :api_token_auth_failed]` | event, legacy | `count` | `reason` | An API request presented a bad bearer token. |
| `[:kanban, :audit, :api_token_created]` | event, legacy | `count` | `user_id`, `board_id`, `token_id` | An API token was created. |
| `[:kanban, :audit, :api_token_revoked]` | event, legacy | `count` | `user_id`, `token_id` | An API token was revoked. |
| `[:kanban, :audit, :comment_deleted_by_owner]` | event, legacy | `count` | `user_id`, `board_id`, `task_id`, `comment_id`, `author_user_id` | A board owner deleted someone else's comment. |
| `[:kanban, :audit, :completion_notes_credential_suspected]` | event, legacy | `count` | `task_id`, `agent_name` | Completion notes looked like they contained a credential. |
| `[:kanban, :audit, :security_considerations_credential_suspected]` | event, legacy | `count` | `task_id`, `agent_name` | A security consideration in a reviewer result looked like it contained a credential. |
| `[:kanban, :audit, :two_factor_enabled]` | event, legacy | `count` | `user_id` | A user turned on two-factor authentication. |
| `[:kanban, :audit, :two_factor_disabled]` | event, legacy | `count` | `user_id`, `method` | A user turned off two-factor authentication. |
| `[:kanban, :audit, :recovery_codes_regenerated]` | event, legacy | `count` | `user_id` | A user regenerated their recovery codes. |
| `[:kanban, :audit, :two_factor_recovery_code_used]` | event, legacy | `count` | `user_id` | A user signed in with a recovery code. |
| `[:kanban, :audit, :login_succeeded_two_factor]` | event, legacy | `count` | `user_id`, `method` | A user completed a two-factor sign-in. |
| `[:kanban, :audit, :two_factor_challenge_failed]` | event, legacy | `count` | `user_id`, `method` | A two-factor challenge failed. |
| `[:kanban, :audit, :permission_denied]` | event, legacy | `count` | `user_id`, `gate` | A user was refused access by a permission gate. |
| `[:kanban, :audit, :sudo_mode_entered]` | event, legacy | `count` | `user_id` | A recently authenticated user passed a sudo-mode check. |
| `[:kanban, :audit, :audit_log_exported]` | event, legacy | `count` | `user_id`, `format` | An admin exported the audit log. |
| `[:kanban, :audit, :org_audit_log_exported]` | event, legacy | `count` | `user_id`, `organization_id`, `format` | An org-admin exported their Organization's audit log. user_id is the org-admin. |
| `[:kanban, :audit, :organization_created]` | event, legacy | `count` | `user_id`, `organization_id` | A site admin created an Organization. user_id is the site admin. |
| `[:kanban, :audit, :organization_updated]` | event, legacy | `count` | `user_id`, `organization_id` | A site admin changed an Organization's details. user_id is the site admin. |
| `[:kanban, :audit, :org_admin_appointed]` | event, legacy | `count` | `user_id`, `organization_id`, `member_user_id`, `account_created` | A site admin made a user an org-admin. user_id is the site admin, member_user_id the appointee. account_created is true when the appointee's account was created for the appointment. |
| `[:kanban, :audit, :org_admin_removed]` | event, legacy | `count` | `user_id`, `organization_id`, `member_user_id` | A site admin removed an org-admin. user_id is the site admin, member_user_id the removed user. |
| `[:kanban, :audit, :org_workspace_created]` | event, legacy | `count` | `user_id`, `organization_id`, `workspace_id` | An org-admin created a workspace for their Organization. user_id is the org-admin. |
| `[:kanban, :audit, :org_workspace_renamed]` | event, legacy | `count` | `user_id`, `organization_id`, `workspace_id` | An org-admin renamed one of their Organization's workspaces. user_id is the org-admin. |
| `[:kanban, :audit, :org_workspace_archived]` | event, legacy | `count` | `user_id`, `organization_id`, `workspace_id` | An org-admin archived one of their Organization's workspaces. user_id is the org-admin. |
| `[:kanban, :audit, :user_deleted]` | event, legacy | `count` | `user_id`, `member_user_id` | A site admin deleted an account. user_id is the site admin, member_user_id the deleted account. |
| `[:kanban, :audit, :user_delete_refused]` | event, legacy | `count` | `user_id`, `member_user_id`, `reason` | An account deletion was refused. user_id is the acting user, member_user_id the target account, reason why: unauthorized, cannot_delete_self, user_has_boards, last_admin or personal_workspace_has_boards. |

### Domain `board`

| Event | Kind | Measurements | Metadata | Description |
|---|---|---|---|---|
| `[:kanban, :board, :creation]` | event, legacy | `count` | `board_id`, `user_id` | A board was created. |
| `[:kanban, :board, :updated]` | event | `count` | `board_id`, `actor_user_id`, `fields` | A board owner changed a board's settings. fields lists the changed field names, never their values. |
| `[:kanban, :board, :deleted]` | event | `count` | `board_id`, `actor_user_id` | A board owner deleted a board, with its columns, tasks and memberships. |
| `[:kanban, :board, :field_visibility_changed]` | event | `count` | `board_id`, `actor_user_id`, `fields` | A board owner changed which task fields the board shows. fields lists the toggled field names. |
| `[:kanban, :board, :member_added]` | event | `count` | `board_id`, `user_id`, `access`, `actor_user_id` | A user was given access to a board. user_id is the member, actor_user_id the owner who added them. |
| `[:kanban, :board, :member_removed]` | event | `count` | `board_id`, `user_id`, `access`, `actor_user_id` | A user was removed from a board. access is the level they held. |
| `[:kanban, :board, :member_access_changed]` | event | `count` | `board_id`, `user_id`, `from_access`, `to_access`, `actor_user_id` | A board member's access level changed. |

### Domain `column`

| Event | Kind | Measurements | Metadata | Description |
|---|---|---|---|---|
| `[:kanban, :column, :created]` | event | `count` | `board_id`, `column_id`, `actor_user_id` | A board owner added a column. |
| `[:kanban, :column, :updated]` | event | `count` | `board_id`, `column_id`, `actor_user_id`, `fields` | A board owner changed a column. fields lists the changed field names, never their values. |
| `[:kanban, :column, :deleted]` | event | `count` | `board_id`, `column_id`, `actor_user_id` | A column was deleted, along with its tasks. |
| `[:kanban, :column, :reordered]` | event | `count`, `column_count` | `board_id`, `actor_user_id` | A board's columns were reordered. column_count is the number of column ids given. |

### Domain `digest`

| Event | Kind | Measurements | Metadata | Description |
|---|---|---|---|---|
| `[:kanban, :digest, :sent]` | event | `count` | `user_id`, `week` | The mailer accepted one user's weekly digest. week is the ISO week, such as "2026-W45". |
| `[:kanban, :digest, :fanout_completed]` | event | `count` | `week` | The weekly digest fan-out finished enqueuing. count is the number of recipients and may be 0. |

### Domain `export`

| Event | Kind | Measurements | Metadata | Description |
|---|---|---|---|---|
| `[:kanban, :export]` | span | `duration` on `:stop` and `:exception`; `row_count` on `:stop` | `kind`, `format` | Data left Stride as a download. kind is :archive_csv, :metrics_pdf, :workspace_metrics, :audit_log or :org_audit_log, format the file type; row_count is measured for the archive CSV only. |

- `[:kanban, :export]` is a span: it emits `[:kanban, :export, :start]`, `[:kanban, :export, :stop]` and `[:kanban, :export, :exception]`.

### Domain `github`

| Event | Kind | Measurements | Metadata | Description |
|---|---|---|---|---|
| `[:kanban, :github, :issue_created]` | event | `count` | `outcome`, `reason` | An issue report to GitHub finished. outcome is :ok or :error, including when GitHub is not configured. reason is :none, :not_configured, :http_error or :transport_error, never the error text. |

### Domain `goal`

| Event | Kind | Measurements | Metadata | Description |
|---|---|---|---|---|
| `[:kanban, :goal, :created_with_tasks]` | event, legacy | `goal_count`, `task_count` | `goal_id`, `column_id` | A goal was created together with its child tasks. |
| `[:kanban, :goal, :completed]` | event | `count` | `goal_id`, `board_id` | The last child of a goal was completed. Emitted once per goal, after the completion commits. |
| `[:kanban, :goal, :promoted_to_ready]` | event | `count`, `task_count` | `goal_id`, `board_id` | A goal and its Backlog children were moved to Ready. task_count is the number of tasks moved. |
| `[:kanban, :goal, :after_goal_succeeded]` | event | `count`, `duration_ms` | `goal_id`, `board_id`, `source` | A goal's after_goal hook succeeded and the goal moved to Done. source is :agent for an agent report or :grace_worker when the grace window expired; duration_ms is the agent's reported run time. |
| `[:kanban, :goal, :after_goal_failed]` | event | `count`, `duration_ms` | `goal_id`, `board_id`, `exit_code` | An agent reported a failed after_goal hook. Only the exit code and duration are sent, never the hook's output. |
| `[:kanban, :goal, :grace_window_scheduled]` | event | `count`, `grace_window_ms` | `goal_id`, `board_id` | The after_goal grace window was scheduled for a goal whose last child completed. |
| `[:kanban, :goal, :grace_window_expired]` | event | `count` | `goal_id`, `board_id` | The after_goal grace window expired with no agent report, and the grace worker moved the goal to Done. |
| `[:kanban, :goal, :reassigned]` | event | `count`, `moved_count`, `skipped_count` | `goal_id`, `board_id`, `actor_user_id`, `assigned_to_id` | A goal and its unstarted children were reassigned. moved_count counts the children moved and skipped_count the claimed children left alone. |
| `[:kanban, :goal, :reprioritized]` | event | `count`, `moved_count`, `skipped_count` | `goal_id`, `board_id`, `actor_user_id`, `priority` | A goal and its unstarted children were given a new priority. moved_count counts the children changed and skipped_count the claimed children left alone. |
| `[:kanban, :goal, :reassignment_undone]` | event | `count`, `moved_count`, `skipped_count` | `goal_id`, `board_id`, `actor_user_id` | A goal reassignment was undone. moved_count counts the children restored and skipped_count those that could no longer be restored. |
| `[:kanban, :goal, :reprioritization_undone]` | event | `count`, `moved_count`, `skipped_count` | `goal_id`, `board_id`, `actor_user_id` | A goal reprioritization was undone. moved_count counts the children restored and skipped_count those that could no longer be restored. |

### Domain `mcp`

| Event | Kind | Measurements | Metadata | Description |
|---|---|---|---|---|
| `[:kanban, :mcp, :request]` | span | `duration` on `:stop` and `:exception` | `method`, `outcome` | An MCP JSON-RPC message was handled. method is a fixed label, never the name the client sent, and outcome is set on stop. |

- `[:kanban, :mcp, :request]` is a span: it emits `[:kanban, :mcp, :request, :start]`, `[:kanban, :mcp, :request, :stop]` and `[:kanban, :mcp, :request, :exception]`.

### Domain `message`

| Event | Kind | Measurements | Metadata | Description |
|---|---|---|---|---|
| `[:kanban, :message, :created]` | event | `count` | `message_id`, `sender_user_id` | An administrator published a broadcast message. |
| `[:kanban, :message, :deleted]` | event | `count` | `message_id`, `sender_user_id` | A broadcast message was deleted, with its dismissals. sender_user_id is its author. |
| `[:kanban, :message, :dismissed]` | event | `count` | `message_id`, `user_id` | A user dismissed a broadcast message for the first time. Dismissing it again emits nothing. |

### Domain `metrics`

| Event | Kind | Measurements | Metadata | Description |
|---|---|---|---|---|
| `[:kanban, :metrics, :retention_completed]` | event | `count`, `batches` | `retention_days` | The daily metrics retention job finished. count is the number of metrics_events rows removed, batches the number of DELETE batches run. |

### Domain `notification`

| Event | Kind | Measurements | Metadata | Description |
|---|---|---|---|---|
| `[:kanban, :notification, :created]` | event | `count` | `notification_id`, `user_id`, `event_type`, `board_id`, `in_app` | A notification was saved for one recipient. user_id is the recipient; in_app is false for an email-only row; board_id is absent for a board-less type. |
| `[:kanban, :notification, :read]` | event | `count` | `notification_id`, `user_id`, `event_type` | A user marked an unread notification read. Marking a read one again emits nothing. |
| `[:kanban, :notification, :all_read]` | event | `count` | `user_id` | A user marked all their notifications read. count is the number marked and may be 0. |
| `[:kanban, :notification, :preference_updated]` | event | `count` | `user_id`, `event_type`, `in_app`, `mail` | A user's delivery preference for one event type changed. in_app and mail are the saved flags; saving the same flags again emits nothing. |
| `[:kanban, :notification, :unsubscribed]` | event | `count` | `user_id`, `event_type` | Email for one event type was turned off from an unsubscribe link. user_id comes from the verified link. |
| `[:kanban, :notification, :email_sent]` | event | `count` | `notification_id`, `user_id`, `event_type` | The mailer accepted a notification email. |
| `[:kanban, :notification, :email_skipped]` | event | `count` | `notification_id`, `reason` | A notification email job sent nothing. reason is :not_found, :already_emailed, :user_disabled, :user_unconfirmed, :not_a_member or :unsubscribed. |
| `[:kanban, :notification, :email_failed]` | event | `count` | `notification_id`, `user_id`, `event_type`, `error` | One notification email delivery attempt failed. error is :permanent_failure, :temporary_failure, :retries_exceeded or :delivery_failed, never the raw mailer reason. |

### Domain `organization`

| Event | Kind | Measurements | Metadata | Description |
|---|---|---|---|---|
| `[:kanban, :organization, :created]` | event | `count` | `organization_id`, `actor_user_id` | A site admin created an Organization. actor_user_id is the site admin. |
| `[:kanban, :organization, :updated]` | event | `count` | `organization_id`, `actor_user_id`, `fields` | A site admin changed an Organization's details. fields lists the changed field names, never their values. |
| `[:kanban, :organization, :member_added]` | event | `count` | `organization_id`, `user_id`, `role`, `actor_user_id`, `account_created` | A user joined an Organization with role, as a new member or a newly appointed org-admin. actor_user_id is the site admin, or the joining user. account_created is true when the account was created for the appointment. |
| `[:kanban, :organization, :member_removed]` | event | `count` | `organization_id`, `user_id`, `role`, `actor_user_id` | A user's Organization membership was deleted. role is the role they held. actor_user_id is the site admin. |
| `[:kanban, :organization, :workspace_created]` | event | `count` | `organization_id`, `workspace_id` | An org-admin created a workspace for their Organization. |
| `[:kanban, :organization, :workspace_renamed]` | event | `count` | `organization_id`, `workspace_id` | An org-admin renamed one of their Organization's workspaces. The name is never in the metadata. |
| `[:kanban, :organization, :workspace_archived]` | event | `count` | `organization_id`, `workspace_id` | An org-admin archived one of their Organization's workspaces. |

### Domain `plan`

| Event | Kind | Measurements | Metadata | Description |
|---|---|---|---|---|
| `[:kanban, :plan, :feature_refused]` | event | `count` | `feature`, `surface` | A plan check refused a paid feature because plans are enforced and the board or user is on the free plan. feature is one of Kanban.Plans.features/0 and surface names the entry point, never a board or user. |

### Domain `pubsub`

| Event | Kind | Measurements | Metadata | Description |
|---|---|---|---|---|
| `[:kanban, :pubsub, :broadcast]` | event, legacy | `count` | `event`, `task_id`, `board_id` | A task or comment change was broadcast over PubSub. |

### Domain `rate_limit`

| Event | Kind | Measurements | Metadata | Description |
|---|---|---|---|---|
| `[:kanban, :rate_limit, :denied]` | event | `count` | `surface` | A rate-limit check refused a request. surface names the limited action, never the key, IP address or identity. |

### Domain `review`

| Event | Kind | Measurements | Metadata | Description |
|---|---|---|---|---|
| `[:kanban, :review, :structured_used]` | event, legacy | `count` | `task_id`, `identifier` | A task's review report, built from the structured review block, was shown. |
| `[:kanban, :review, :fallback_used]` | event, legacy | `count` | `task_id`, `identifier` | A task's review report, parsed from the legacy review summary, was shown. |

### Domain `review_diff_panel`

| Event | Kind | Measurements | Metadata | Description |
|---|---|---|---|---|
| `[:kanban, :review_diff_panel, :opened]` | event, legacy | `system_time`, `count` | `task_id` | A reviewer opened the diff panel for a task in the review queue. |
| `[:kanban, :review_diff_panel, :closed]` | event, legacy | `system_time`, `count` | `task_id` | A reviewer closed the diff panel in the review queue. |

### Domain `target`

| Event | Kind | Measurements | Metadata | Description |
|---|---|---|---|---|
| `[:kanban, :target, :created]` | event | `count` | `target_id`, `actor_user_id` | A user created a delivery target. actor_user_id is its owner. |
| `[:kanban, :target, :updated]` | event | `count` | `target_id`, `actor_user_id`, `fields` | A target's owner changed it. fields lists the changed field names, never their values; saving no change emits nothing. |
| `[:kanban, :target, :archived]` | event | `count` | `target_id`, `actor_user_id` | A target's owner archived an active, complete target. |
| `[:kanban, :target, :unarchived]` | event | `count` | `target_id`, `actor_user_id` | A target's owner restored an archived target. |
| `[:kanban, :target, :goal_assigned]` | event | `count` | `target_id`, `goal_id`, `board_id`, `actor_user_id` | A goal was attached to a target. board_id is the goal's board; assigning the target a goal already has emits nothing. |
| `[:kanban, :target, :goal_unassigned]` | event | `count` | `target_id`, `goal_id`, `board_id`, `actor_user_id` | A goal was detached from its target. target_id is the target it left; a goal with no target emits nothing. |
| `[:kanban, :target, :status_changed]` | event | `count` | `target_id`, `from_status`, `to_status` | The status sweep recorded a new delivery status for a target. from_status is nil on the first observation; both are :on_track, :at_risk, :missed or :complete. |

### Domain `task`

| Event | Kind | Measurements | Metadata | Description |
|---|---|---|---|---|
| `[:kanban, :task, :creation]` | event, legacy | `count` | `task_id`, `column_id` | A task was created. |
| `[:kanban, :task, :archived]` | event, legacy | `count` | `task_id`, `identifier`, `via`, `goal_id` | A task was archived, directly, in bulk (via: :bulk) or with its goal (via: :goal_cascade). |
| `[:kanban, :task, :unarchived]` | event, legacy | `count` | `task_id`, `identifier` | A task was restored from the archive. |
| `[:kanban, :task, :bulk_archived]` | event, legacy | `count` | `board_id` | A batch of completed tasks on a board was archived. count is the number of tasks archived and may be 0. |
| `[:kanban, :task, :completed]` | event, legacy | `count` | `task_id`, `completed_by` | An agent completed a task. |
| `[:kanban, :task, :moved_to_review]` | event, legacy | `count`, `time_spent_minutes` | `task_id`, `completed_by_id` | A completed task moved to the Review column. time_spent_minutes is an integer, or absent when unknown. |
| `[:kanban, :task, :returned_to_doing]` | event, legacy | `count` | `task_id`, `reviewed_by`, `review_status` | A reviewed task was sent back to Doing. |
| `[:kanban, :task, :changed_files_missing]` | event, legacy | `count` | `task_id`, `identifier`, `board_id` | A task reached review reporting changed files but with no uploaded diff. |
| `[:kanban, :task, :updated]` | event | `count` | `task_id`, `board_id`, `fields`, `source`, `actor_user_id` | A task was edited in the UI (source :ui) or through the API (:api). fields lists the changed field names, never their values. |
| `[:kanban, :task, :moved]` | event | `count` | `task_id`, `board_id`, `from_column_id`, `to_column_id` | A task was moved from one column to another. |
| `[:kanban, :task, :reordered]` | event | `count`, `task_count` | `task_id`, `column_id`, `board_id` | Tasks were reordered within one column: one task (with task_id) or a whole column (with task_count, the number of task ids given). |
| `[:kanban, :task, :deleted]` | event | `count` | `task_id`, `board_id` | A task was deleted. |
| `[:kanban, :task, :claimed]` | event | `count` | `task_id`, `board_id`, `user_id` | A task was claimed, through the API or the MCP server. user_id is the claiming user. |
| `[:kanban, :task, :unclaimed]` | event | `count` | `task_id`, `board_id`, `user_id`, `has_reason` | A claimed task was released back to Ready. has_reason says whether a reason was given; the reason itself is never sent. |
| `[:kanban, :task, :claim_expired]` | event | `count` | `task_id`, `board_id`, `user_id` | A claim expired before the task was completed. Emitted once per claim; user_id is the assignee whose claim expired. |
| `[:kanban, :task, :review_approved]` | event | `count` | `task_id`, `board_id`, `reviewer_user_id` | A reviewer approved a task in the review queue. |
| `[:kanban, :task, :review_changes_requested]` | event | `count` | `task_id`, `board_id`, `reviewer_user_id` | A reviewer requested changes to a task in the review queue. The review notes are never sent. |
| `[:kanban, :task, :comment_created]` | event | `count` | `task_id`, `board_id`, `comment_id`, `user_id`, `by_agent` | A comment was added to a task. user_id is the author and by_agent says whether an agent wrote it; the comment text is never sent. |
| `[:kanban, :task, :unblocked]` | event | `count` | `task_id`, `board_id` | A blocked task became unblocked because the last of its dependencies was completed. |

### Domain `telemetry`

| Event | Kind | Measurements | Metadata | Description |
|---|---|---|---|---|
| `[:kanban, :telemetry, :metadata_dropped]` | event | `count` | `event_name`, `reason`, `keys` | Kanban.Telemetry dropped metadata keys from an event, because they were forbidden or undeclared. count is the number of keys dropped. Carries key names only, never values. |

### Domain `user`

| Event | Kind | Measurements | Metadata | Description |
|---|---|---|---|---|
| `[:kanban, :user, :registration]` | event, legacy | `count` | `user_id` | A user registered. |
| `[:kanban, :user, :login]` | event, legacy | `count` | `user_id` | A user signed in through the browser. Renewing an existing session token does not count. |
| `[:kanban, :user, :logged_out]` | event | `count` | `user_id` | A user signed out of the browser. user_id is absent when nobody was signed in. |
| `[:kanban, :user, :sessions_revoked]` | event | `count` | `user_id` | A user's open sessions were disconnected after a password change or reset. count is the number of tokens revoked and may be 0; user_id is absent when no token names the user. |
| `[:kanban, :user, :password_changed]` | event | `count` | `user_id` | A signed-in user changed their password. |
| `[:kanban, :user, :password_reset_completed]` | event | `count` | `user_id` | A user set a new password through a password reset link. |
| `[:kanban, :user, :email_change_requested]` | event | `count` | `user_id` | A user asked to change their email address and a confirmation link was sent. Neither address is sent. |
| `[:kanban, :user, :email_changed]` | event | `count` | `user_id` | A user confirmed an email change and their address was updated. Neither address is sent. |
| `[:kanban, :user, :confirmed]` | event | `count` | `user_id` | A user confirmed their account. |
| `[:kanban, :user, :name_changed]` | event | `count` | `user_id` | A user changed their display name. The name itself is never sent. |
| `[:kanban, :user, :type_changed]` | event | `count` | `user_id`, `from_type`, `to_type` | A user's type changed, for example from :user to :admin. It carries no actor_user_id, because update_user_type/2 is not given one. |
| `[:kanban, :user, :disabled]` | event | `count` | `user_id`, `actor_user_id` | An administrator disabled an enabled user. user_id is the user, actor_user_id the administrator. |
| `[:kanban, :user, :enabled]` | event | `count` | `user_id`, `actor_user_id` | An administrator enabled a disabled user. user_id is the user, actor_user_id the administrator. |
| `[:kanban, :user, :deleted]` | event | `count` | `user_id`, `actor_user_id` | An administrator deleted a user. user_id is the deleted user's id, actor_user_id the administrator. |
<!-- event-reference:end -->
