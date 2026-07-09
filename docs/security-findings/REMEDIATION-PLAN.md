# Security Remediation Plan (G310)

> Triage output for the 12 defects filed by the comprehensive security review
> (G309). Ranked by severity, deduplicated, with `needs_review` set on the two
> medium-and-above fixes. This is the fix order for G310.

## Fix order

| # | ID | Sev | Review? | Fix summary |
|---|----|-----|:------:|-------------|
| 1 | **D110** | **HIGH** | ✅ | Gate the task create/edit save path + form `handle_params` on modify access (`can_modify?`) — closes the read-only → write privilege escalation |
| 2 | **D114** | **MEDIUM** | ✅ | Reject `..`/absolute paths in `changed_files[].path`, mirroring `KeyFile` (shared `relative_safe?/1` helper) |
| 3 | D105 | med prio* | — | Dedicated short reset-password token window (separate from the 7-day change-email window) |
| 4 | D107 | low | — | Add `expires_at`/TTL to API tokens |
| 5 | D108 | low | — | Add board-write authz to the `after_goal` API endpoint |
| 6 | D109 | low | — | Add board-write re-check to API `unclaim`/`create`/`update` |
| 7 | D106 | low | — | Enforce confirmation gate in `require_admin`/`require_admin_user`/`require_sudo_mode` |
| 8 | D111 | low | — | Set `TaskComment.task_id` server-side instead of casting it |
| 9 | D112 | low | — | Tighten `parse_time_range` to a fixed allow-list |
| 10 | D113 | low | — | CSP hardening: drop `style-src 'unsafe-inline'`; add `base-uri`/`form-action`/`object-src` |
| 11 | D115 | low | — | Dev `SECRET_KEY_BASE` placeholder fails closed for a running server |
| 12 | D116 | low | — | Safe prod `DATABASE_SSL` default with explicit 6PN opt-out |

\* D105 is **low severity** (single-use, limited blast radius) but carries **medium
priority** because it is an account-takeover primitive; per policy `needs_review`
tracks severity, so it is not review-gated.

## Rationale

- **D110 first** — the only privilege escalation; highest impact, and its fix
  pattern (`authorize_modify_for_task` / `can_modify?`) is already established for
  the delete/move handlers, so it's low-risk to apply.
- **D114 second** — the only other medium; a small, well-scoped path-validation
  fix on a public API surface.
- **D108/D109** pair naturally (same `board_write_access?` helper) and can share a
  branch of work if desired.
- **D115/D116** are config-only and independent of the app-code fixes.

## Working method (per G310 task)

Rebase onto latest `origin/main` → invoke `stride-development-guidelines` (and
`phoenix-framework` for web-layer changes) → implement with TDD → run the full
gate (`mix test --cover`, `format --check`, `credo --strict`, `sobelow`) →
commit → **push** (per-task, per the push-often cadence). The two `needs_review`
fixes (D110, D114) stop in Review for human approval before their `after_review`.

## No duplicates

All 12 findings are distinct surfaces. The closest pair — D108 (`after_goal`) and
D109 (`unclaim`/`create`/`update`) — are separate endpoints sharing one helper;
kept as two defects for independent verification.
