# Security Findings — Injection & Data-Access Safety (W1595)

> Domain 4 of the comprehensive security review (G309). Manual analysis plus an
> independent `stride-security-review` full-file pass; the finding hand-verified.
>
> **Verdict: solid.** 0 critical · 0 high · 0 medium · 1 low (defense-in-depth) ·
> 9 boundaries verified clean.

## Surface reviewed

`metrics.ex`, `metrics/task_queries.ex`, `tasks/positioning.ex`,
`tasks/dependencies.ex`, `tasks/compliance.ex`, `tasks/agent_queries.ex`,
`api/task_param_filter.ex`, `metrics_pdf_controller.ex`,
`archive_export_controller.ex`, `metrics_live/helpers.ex`.

## D112 — `parse_time_range` allow-list gap (low)

`Helpers.parse_time_range/1` (`helpers.ex:99`) resolves the user `time_range`
param via `String.to_existing_atom/1`, returning **any** existing atom rather than
the five valid ranges. That value reaches `generate_filename/4` where
`Atom.to_string(time_range)` is interpolated into the `content-disposition` header
(`metrics_pdf_controller.ex:83,126`). Near-zero live exploitability — header (CRLF)
or quote injection would require an existing atom whose name contains `\r`/`\n`/`"`,
which does not occur among the app's atoms, and the query side degrades unknown
atoms to a 29-day window. A latent W1431 allow-list gap. **Fix:** pattern-match
`parse_time_range` to the five known atoms with a `:last_30_days` fallback.

## Verified-clean boundaries

- **Every `fragment/2` site** (metrics, task_queries, positioning, dependencies,
  compliance, agent_queries) uses `?`/`^`-bound placeholders on schema columns or
  pinned params — **no string interpolation into any fragment**.
- **Every `Repo.query!`** (positioning, compliance, identifiers advisory locks)
  uses `$1` bind parameters; no user string reaches raw SQL.
- **No `String.to_atom/1` on external input anywhere in `lib/`** — every coercion
  uses `String.to_existing_atom/1` (with a rescue), so atom exhaustion (CWE-410)
  is not reachable from request input.
- **`task_param_filter.ex`** mass-assignment deny-lists are well-formed and fail
  closed on unparseable `column_id`; changeset allow-lists are the second layer.
- **Both export controllers** (`metrics_pdf_controller`, `archive_export_controller`)
  authorize the board per-user via `Boards.get_board(board_id, user)` (no IDOR) and
  sanitize the board name into the filename with `~r/[^a-zA-Z0-9_-]/ → "_"`.
- **`metric` param** rejected up front via `when metric not in @valid_metrics` (W1432)
  before it reaches template dispatch (allow-list map).

### Note (not a live finding)
`agent_queries` `get_tasks_modifying_file/1`, `get_tasks_requiring_technology/1`,
and `get_tasks_with_automated_verification/0` are not board-scoped, but they have
no web/API caller. If ever wired to an endpoint, add a `board_id` scope + authz.
