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
because `:telemetry` appends `:start`, `:stop` and `:exception` to it.

Legacy entries keep their existing names, such as `[:kanban, :board, :creation]`,
even where they break the naming rule, because metrics, dashboards and the
stored `metrics_events` history depend on them. Never rename one.

### Runtime-named families

Two families build their event name from an action atom at runtime. Each
action has its own catalog entry, generated from a list of
`{action, metadata keys, description}` tuples in the catalog module:

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

## Emitting an event

```elixir
Kanban.Telemetry.emit([:kanban, :task, :changed_files_missing], %{count: 1},
  task_id: task.id, identifier: task.identifier, board_id: board_id)

Kanban.Telemetry.span([:kanban, :board, :export], %{board_id: board.id}, fn ->
  {export_board(board), %{board_id: board.id}}
end)
```

`emit/3` wraps `:telemetry.execute/3`, and `span/3` wraps `:telemetry.span/3`
with the same semantics, so `Telemetry.Metrics` duration summaries work
unchanged. Measurements and metadata may be maps or keyword lists. (The span
example names an operation that is not in the catalog yet; add an entry before
emitting one.)

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
   audit action is a new tuple in `@api_actions` or `@audit_actions`.
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
