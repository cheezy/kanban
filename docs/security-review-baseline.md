# Security Review Baseline & Surface Inventory

> Foundation artifact for the comprehensive security review tracked under Stride
> goal **G309** (review) and **G310** (remediation). This document is the shared
> attack-surface map and the known-good tooling baseline that the nine domain
> reviews (W1592–W1600) each drill into. Findings are diffs against the state
> recorded here.
>
> **Task:** W1591 · **Date:** 2026-07-06 · **Toolchain:** Elixir 1.20.2-otp-28,
> Erlang/OTP 28 (system), against `~> 1.20` requirement in `mix.exs`.

## 1. Tooling baseline (known-good starting point)

All security tooling was run against the working tree at review start. This is
the reference state — any *new* finding is a regression against a green baseline.

| Tool | Command | Result |
|------|---------|--------|
| Sobelow (static analysis) | `mix sobelow` (reads `.sobelow-conf`) | **SCAN COMPLETE — no findings.** Config: `threshold: :low`, empty `ignore` list, empty `ignore_files` — a maximally-thorough scan with nothing suppressed. |
| Dependency CVE audit | `mix deps.audit` | **No vulnerabilities found.** |
| Retired/advisory packages | `mix hex.audit` | **No retired or security-advisory packages found.** |
| Outdated dependencies | `mix hex.outdated` | **All 35 dependencies up-to-date** (current == latest for every dep). |

### Tooling-hygiene note (candidate finding — Domain 7) — RESOLVED (W1683)

The invocation guides once referenced a mistyped Sobelow config filename
(`…-config` instead of the on-disk `.sobelow-conf`, no `ig`). Sobelow's
`--config` flag reads `.sobelow-conf` by its own fixed convention and ignores
the trailing positional argument, so the scan always ran against the intended
config regardless. W1683 corrected the stray reference in `.stride_dev.md` (the
CI workflow already used `.sobelow-conf`), so every tracked invocation now names
the real file. Not a vulnerability — logged here and under the
secrets/config/deploy domain (W1598) as tooling hygiene.

## 2. Routes, pipelines, and auth boundaries

Source: `lib/kanban_web/router.ex`. Four pipelines, and the trust boundary each
route sits behind is the single most important fact for the authz reviews.

### Pipelines

| Pipeline | Plugs (security-relevant) | Trust level |
|----------|---------------------------|-------------|
| `:browser` | `fetch_session`, `protect_from_forgery` (CSRF), `put_secure_browser_headers` (with placeholder `default-src 'self'` CSP), `CspNonce`, `fetch_current_scope_for_user`, `Locale` | Session-cookie auth; CSRF-protected |
| `:api` | `ApiTelemetry`, **`AuthenticateApiToken`** | Bearer-token auth (the agent surface) |
| `:api_public` | `ApiTelemetry` only | **Unauthenticated** — only `/api/agent/onboarding` |
| (admin overlay) | `:browser` + `require_authenticated_user` + `require_admin_user` | Admin-only |

### Route → boundary map

- **Public, unauthenticated (`:browser`, no auth):** marketing pages (`/`,
  `/about`, `/pricing`, `/privacy`, `/security`, `/terms`, `/product`,
  `/workflows`, `/changelog`, `/tango`, `/acceptable-use`), `POST /locale/:locale`.
- **Public LiveViews (`:current_user` / `:public` / `:public_app_shell`):**
  register, log-in, confirm, forgot/reset-password, confirmation-pending,
  `/issue`, `/resources`, `/resources/:id`. These mount `current_scope` but do
  **not** require auth — validation of what an anonymous user can see/do here
  belongs to the auth review (W1592).
- **Authenticated (`:require_authenticated_user`):** all `/boards*`, `/agents`,
  `/review`, `/metrics*`, `/users/settings*`, the metrics/archive export
  controllers, `POST /users/update-password`.
- **Admin-only (`require_admin_user`):** `/admin/messages`, LiveDashboard
  (`/admin/dashboard`), ErrorTracker (`/admin/errors`).
- **Dev-only (compile-gated `:dev_routes`):** Swoosh mailbox preview at
  `/dev/mailbox`. Confirm this cannot compile into production (W1598).
- **API, token-authenticated (`:api`):** the full task lifecycle — `next`,
  `claim`, `batch`, `unclaim`, `complete`, `changed_files`, `mark_reviewed`,
  `mark_done`, `after_goal`, dependency/tree reads, and the `resources "/tasks"`
  CRUD (index/show/create/update).
- **API, public (`:api_public`):** `GET /api/agent/onboarding` only.

## 3. Per-domain surface inventory

Each domain review below has a concrete, non-exhaustive starting file list.
"Verify held" means confirm a previously-shipped hardening still stands.

### W1592 — Authentication & session management
- `lib/kanban_web/user_auth.ex` — scope plugs, `on_mount` hooks, remember-me, `renew_session`.
- `lib/kanban_web/controllers/user_session_controller.ex` — login, logout, register, `update_password`.
- `lib/kanban/accounts.ex`, `lib/kanban/accounts/user.ex` — credential verification, confirmation gate, password reset.
- `lib/kanban/api_tokens.ex`, `lib/kanban/api_tokens/api_token.ex` — token issuance, hashing, revocation.
- **Verify held:** confirmation-gate work (W1485–W1487), per-dev `SECRET_KEY_BASE`.

### W1593 — API token authN & capability authZ
- `lib/kanban_web/plugs/authenticate_api_token.ex` — bearer extraction, token→scope.
- `lib/kanban_web/controllers/api/task_controller.ex`, `agent_controller.ex`, `completion_result_gate.ex`.
- `lib/kanban/api_tokens.ex` — token→user→board resolution, capability enforcement.
- **Verify held:** live-board gate (W1430), owner gate (W1434), changed_files scope (W1433).

### W1594 — IDOR & cross-board access scoping
- `lib/kanban/boards.ex` — board access + membership scoping (`BoardScope`).
- `lib/kanban/tasks/queries.ex`, `lib/kanban/tasks/goals.ex` — must be board-scoped.
- Changesets guarding ownership fields: `lib/kanban/messages/message.ex` (D93/D94), `lib/kanban/columns/column.ex` (D93), `lib/kanban/boards/board_user.ex`.
- **Verify held:** `board_id` mass-assignment blocks (D93), `sender_id` cast removal (D94).

### W1595 — Injection & data-access (SQL, atoms, params)
- `fragment(...)` sites: `lib/kanban/metrics.ex`, `lib/kanban/metrics/task_queries.ex`, `lib/kanban/boards.ex`, `lib/kanban/tasks/agent_queries.ex`, `lib/kanban/tasks/compliance.ex`, `lib/kanban/tasks/dependencies.ex`.
- Param boundary: `lib/kanban_web/controllers/api/task_param_filter.ex`.
- `String.to_atom` risk sweep across `lib/`.
- **Verify held:** metric-param allow-list (W1431/W1432).

### W1596 — XSS, output encoding & CSP
- `lib/kanban_web/plugs/csp_nonce.ex` + router `put_secure_browser_headers`.
- `raw/1` sinks: `lib/kanban_web/components/review_report_panel.ex`, `lib/kanban_web/live/resources_live/components.ex` (user-content-adjacent); `metrics_pdf_html/*.heex`, `page_html/{changelog,workflows}.html.heex` (server-controlled — lower priority, still confirm).
- `lib/kanban_web/review_report_helpers.ex` — diff/report rendering.

### W1597 — Input validation, changesets & file-path handling
- `lib/kanban/tasks/task.ex` (`@api_update_fields`/`@api_create_fields` allow-lists, length validators), `lib/kanban/schemas/task/key_file.ex`, `verification_step.ex`.
- `lib/kanban_web/controllers/api/changed_files_transport.ex` — path-traversal surface.
- `lib/kanban/tasks/db_errors.ex` — DB-error→422 mapping (W1413).
- **Verify held:** length-validator regression guard (W1412), 422 translation (W1413/W1414).

### W1598 — Secrets, config & deployment hardening
- `config/runtime.exs`, `config/dev.exs`, `config/prod.exs` — secret sourcing, dev-fallback isolation.
- `Dockerfile.production`, `Dockerfile.review` — base-image digest pinning (W1429).
- `fly.production.toml`, `fly.review.toml` — env exposure.
- `.sobelow-conf` skip/ignore list; the config-filename naming discrepancy above (resolved in W1683).
- Dev-route compile gate (`:dev_routes`).
- **Verify held:** Chrome/base-image pinning (W1429), audit-credential env move (W1435, D-config).

### W1599 — Dependencies & supply-chain
- `mix.exs`, `mix.lock` — 35 deps, all current (baseline §1).
- Native/precompiled vector: `rustler_precompiled`, `mdex`, `bcrypt_elixir`, `chromic_pdf` (downloads Chrome).
- **Verify held:** plug retirement fix (1.20.1→1.20.2 lineage).

### W1600 — SSRF & hook/file-transport execution
- `lib/kanban/reviews.ex` — `diff_url` scheme/host allow-list (W1431).
- `lib/kanban/github.ex` — server-side fetches (only outbound-HTTP context module found).
- `lib/kanban_web/controllers/api/changed_files_transport.ex` — file-transport decode.
- `lib/kanban/hooks.ex` — hook env-var forwarding into executed commands.

## 4. Codebase scale (context)

- ~49k LOC of Elixir (`lib/`).
- 66 context files (`lib/kanban/`); 190 web files (`lib/kanban_web/`).
- 66 files reference auth/scope primitives (`BoardScope`, `require_authenticated`, `current_scope`, `authorize`).
- 6 `fragment(...)` context modules; 13 changeset-bearing modules; 1 outbound-HTTP context (`github.ex`).

## 5. Review conventions

- Each domain review files findings as **defect tasks under G310**, with
  severity (critical/high/medium/low), `file:line`, a concrete repro/attack
  path, and a suggested fix. A domain with no findings records an explicit
  clean bill citing the evidence reviewed.
- Severity taxonomy and the DoS/rate-limit exclusion follow the
  `stride-security-review` skill.
- Every finding is hand-traced against the code to confirm exploitability
  before filing — no pattern-match-only findings.
