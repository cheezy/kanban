# Project-level code review checks

Checklist consumed by the Stride task-reviewer agent (`stride:task-reviewer`)
on every task's diff. Each top-level bullet is **one check**; the reviewer
evaluates it as `met` or `not_met` against the diff and surfaces failures in
the task's `## Review Report`.

**Severity rule:** bullets prefixed with `CRITICAL:` are critical-severity
(must fix before completion). All other bullets are important-severity
(should fix before completion). Indented lines under a bullet are context
for the reviewer, not separate checks. Section headings are for human
organization and are NOT parsed as checks.

Keep the list practical (~25 bullets) — bloat dilutes signal and slows the
reviewer. If a check overlaps with what Credo / Sobelow / format / coverage
already catch automatically, leave it out: those tools run in the
`after_doing` hook and don't need to be re-checked here.

## Authentication and authorization

- CRITICAL: Any new context-module function that reads or mutates user-scoped data takes `current_scope` as its first argument and filters every query by `current_scope.user.id` (or the appropriate scope field). Functions that ignore `current_scope` and return raw records across users are a hard reject — they leak data across tenancy boundaries.
- CRITICAL: New LiveView routes are placed inside the existing `live_session :require_authenticated_user` block when they require login, or inside `live_session :current_user` when they work signed-out. A new top-level `live_session` block in `router.ex` is almost always wrong — duplicate `live_session` names break routing.
- CRITICAL: Templates and LiveViews use `@current_scope.user` to read the signed-in user. Any new reference to `@current_user` in a template or LiveView mount is a regression — `phx.gen.auth` does not assign it.
- New controller routes that mutate user data are placed inside a scope that pipes through `:require_authenticated_user`. Public mutation routes are rejected.

## LiveView / context boundary

- CRITICAL: No Ecto query (`from`, `Repo.all`, `Repo.get`, `Repo.one`, `Repo.update_all`, etc.) appears directly in a `lib/kanban_web/live/**/*.ex` file. All persistence calls live in context modules under `lib/kanban/`. LiveViews call context functions; they never `import Ecto.Query` or alias `Repo`.
- LiveView modules begin their render with `<Layouts.app flash={@flash} ...>` and pass `current_scope={@current_scope}` to it. Templates that bypass `Layouts.app` lose flash and scope plumbing.
- Forms in LiveView use the `<.input>` component from `core_components.ex` rather than raw `<input>` tags. Custom `<input>` wrappers should justify why `<.input>` was insufficient.
- Icons use the `<.icon name="hero-..."/>` component from `core_components.ex`. New `Heroicons.*` module references or raw `<svg>` blocks for stock icons are a regression.
- New buttons use the `<.button>` component without custom classes unless the task spec calls for a custom style. Bare `<button class="...">` should justify the deviation.

## Theming and dark mode

- All new UI markup uses theme-aware daisyUI tokens (`text-base-content`, `bg-base-100`, `bg-base-200`, `border-base-300`, `text-primary`, etc.) instead of hardcoded Tailwind shades (`text-gray-900`, `bg-white`, `border-gray-200`, etc.). Hardcoded shades break the dark-mode contract documented in `docs/dark-mode-contract.md`.
- Any new form, modal, button, or layout component renders correctly in both light and dark mode. If the diff touches a `*.heex` template, the change passes `mix dark_mode.scan` (the scanner runs in `mix precommit`).

## Localization

- All user-visible strings in new templates or LiveViews are wrapped in `gettext("...")`. Hardcoded English strings ("Save", "Cancel", "Are you sure?") in templates are a regression — they don't translate.
- If the diff adds or modifies `gettext("...")` calls, `priv/gettext/<locale>/LC_MESSAGES/*.po` files are synchronized (run `mix gettext.extract --merge`). Stale `.po` files leave new strings untranslated in all locales.

## Function and module shape

- New context functions return `{:ok, result}` / `{:error, reason}` tuples for fallible operations. Functions that raise on failure as their primary error path (without an accompanying `!`-variant) are a regression — Elixir convention reserves raise for `function!` variants.
- Predicate functions in new code are named with a trailing `?` and do NOT start with `is_` (e.g., `archived?/1`, not `is_archived/1`). The `is_*` prefix is reserved for guards.
- New module additions stay under ~600 lines. Modules approaching the cap should be split along the seam patterns documented in `AGENTS.md` (positioning, dependencies, validation, queries as separate modules).
- New functions stay under cyclomatic complexity 9. Deeply nested `case`/`with` blocks should be extracted into named helper functions before review.

## Input handling and security

- CRITICAL: No `String.to_atom/1` on user input (request params, form fields, URL segments). Use `String.to_existing_atom/1` or a hardcoded allow-list. `String.to_atom` on user input is an unbounded memory leak.
- CRITICAL: No raw SQL interpolation. All dynamic SQL goes through Ecto query expressions or parameterized fragments. String-concatenated SQL with user input is a hard reject.
- New external HTTP calls use the `Req` library (already in deps). New `:httpoison`, `:tesla`, or `:httpc` additions require an explicit justification in the task description.

## Testing

- New context functions have at least one unit test covering the happy path AND one covering an error path. Functions added without any test coverage are a regression — `mix test --cover` would already flag the line, but the structure also matters.
- New LiveView event handlers (`handle_event`, `handle_info`) have at least one integration test in `test/kanban_web/live/...` exercising the event. LiveView logic changes without LiveView tests are a regression.

## Database / migrations

- New migrations are reversible — every `up` change has a corresponding `down`, or the migration uses the `change/0` callback with reversible primitives. One-way migrations should justify why in a comment.
- New foreign keys reference the parent's `id` column with an explicit `on_delete:` strategy (`:delete_all`, `:nilify_all`, or `:nothing` not the default). Missing `on_delete:` strategies cause runtime errors during cascade operations.

## Cross-plugin compatibility

- New text rendered into goal/task markdown files (via stride-lite or stride-lite-copilot skill output) avoids Claude Code-specific tool names (`Edit`, `Write`, `Bash`, `Agent`, `Skill`, `Grep`, `Glob`). The same markdown is consumed by Copilot's task-reviewer agent and PascalCase tool nouns confuse cross-runtime users.
