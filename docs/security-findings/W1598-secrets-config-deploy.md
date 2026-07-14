# Security Findings — Secrets, Config & Deployment Hardening (W1598)

> Domain 7 of the comprehensive security review (G309). Manual analysis plus an
> independent `stride-security-review` full-file pass.
>
> **Verdict: strong; no committed prod secrets.** 0 critical · 0 high · 0 medium ·
> 2 low · 2 info · several boundaries verified clean.

## Surface reviewed

`config/{runtime,config,dev,prod,test}.exs`, `Dockerfile.production`,
`Dockerfile.review`, `fly.production.toml`, `fly.review.toml`, `.sobelow-conf`,
`application.ex`, the `:dev_routes` compile gate in `router.ex`.

## Findings filed (both low)

| ID | Finding | Where |
|----|---------|-------|
| **D115** | Dev `SECRET_KEY_BASE` placeholder is a committed, publicly-known key; a tunneled/exposed dev server using it lets anyone forge sessions & signed tokens | `config/dev.exs:34` |
| **D116** | Prod `DATABASE_SSL` defaults to `disable` (no TLS) — safe on Fly 6PN today, but env-drift to a public DB would ship credentials/queries in cleartext | `config/runtime.exs:111` |

Both are **contained**: the dev key **cannot bleed to prod** (prod sources
`SECRET_KEY_BASE` from env via `runtime.exs`, which raises when missing), and the
DB-TLS-off default is mitigated by Fly's isolated 6PN WireGuard network. The fixes
make each **fail closed**: D115 refuses to start the dev *server* with the
placeholder active (non-server Mix tasks still work); D116 defaults to a safe TLS
mode with an explicit, documented 6PN opt-out (or a deploy-time host→SSL guard).

## Verified-clean boundaries

- **No committed production secrets.** `runtime.exs` reads `DATABASE_URL`,
  `SECRET_KEY_BASE`, `SMTP_*`, `GITHUB_TOKEN` from env and **raises** when
  `DATABASE_URL`/`SECRET_KEY_BASE` are missing.
- **Docker images digest-pinned (W1429).** Both Dockerfiles pin `BUILDER_IMAGE`
  and `RUNNER_IMAGE` by `@sha256:` digest; no secrets in `ARG`/`ENV`; Chrome
  installed via a verified GPG key.
- **Dev routes compile-gated.** `router.ex:89` uses
  `Application.compile_env(:kanban, :dev_routes)`, set only in `config/dev.exs`, so
  `/dev/mailbox` cannot compile into the prod release. LiveDashboard is separately
  behind `:require_authenticated_user` + `:require_admin_user`.
- **Sobelow hides nothing.** `.sobelow-conf` has `skip: false`, `ignore: []`,
  `ignore_files: []`, `threshold: :low` — no security-relevant suppressions.

## Info (not actionable)

- `config/test.exs` commits a test `secret_key_base` (test-only, `server: false`,
  can't reach prod).
- `config/config.exs` commits a LiveView `signing_salt` — not secret by Phoenix
  design; forgery still requires the env-sourced prod `secret_key_base`.

## Cross-reference

The Sobelow config-filename naming discrepancy noted in the W1591 baseline
(`docs/security-review-baseline.md` §1) belongs to this domain — a
tooling-hygiene nit, not a vulnerability. Resolved in W1683: the stray
`.stride_dev.md` reference now names the real `.sobelow-conf` file.
