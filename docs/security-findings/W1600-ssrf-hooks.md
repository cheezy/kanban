# Security Findings — SSRF & Hook/File-Transport Execution (W1600)

> Domain 9 of the comprehensive security review (G309). Manual analysis plus an
> independent `stride-security-review` full-file pass.
>
> **Verdict: clean.** 0 findings (0 critical/high/medium/low). No exploitable
> SSRF, command injection, or `diff_url` scheme bypass.

## Surface reviewed

`reviews.ex`, `github.ex`, `api/changed_files_transport.ex`, `hooks.ex`,
`hooks/environment.ex`, `components/review_diff_panel.ex`, plus a repo-wide sweep
for `Req.` / `:httpc` / `HTTPoison` and any URL built from user/task input.

## Verified-clean boundaries

- **`diff_url` (W1431) — never fetched server-side.** The agent/user-supplied
  per-file `diff_url` is only rendered as an `href` (`review_diff_panel.ex:290`),
  gated by a **fail-closed** `http`/`https` scheme allow-list
  (`allowed_diff_url_scheme?/1`, `:380`). `javascript:`, `data:`, `file://`,
  `gopher://`, protocol-relative `//evil`, and control-char scheme-smuggling all
  return false and suppress the link. Even an allowed http(s) value is a
  reviewer-initiated client navigation (`target=_blank rel=noopener`), not a
  server fetch — so no SSRF.
- **`github.ex` — the only server-side outbound call.** `create_issue/3` POSTs to
  the hardcoded `@github_api_url` (`https://api.github.com`) plus a **config-sourced**
  `repo` (operator config, not request input). User-controlled `title`/`body` go
  only in the JSON body, never the URL/host/headers. Fixed scheme, fixed host — no
  SSRF, no CRLF header injection.
- **`changed_files_transport` — no fetch.** Base64/gzip-decodes an inline envelope
  and validates JSON; constructs no URL, dereferences no `diff_url`. Bounded
  streaming inflate (5MB decoded / 10MB encoded).
- **Hooks — server does not execute them.** `Environment.build/3` composes a map
  with **fixed literal keys** (`TASK_ID`, `TASK_TITLE`, …) and user data as values;
  `hooks.ex` returns this as metadata JSON to the agent, which executes hooks
  **locally**. No `System.cmd`/`:os.cmd`/`System.shell`/`Port.open` sink in the
  server path — no server-side command injection.

## Out-of-scope notes (documentation, not defects)

- **Agent-side hook authors** should reference `$TASK_TITLE`/`$TASK_DESCRIPTION`
  strictly as quoted env-var expansions and never `eval` them — a hook script that
  interpolates these into a shell command could be injectable on the *agent's*
  machine (outside this codebase).
- If `github.ex`'s `repo` ever becomes user-supplied, validate it against
  `^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$` before path interpolation.
- Optional defense-in-depth: add a host allow-list on `diff_url` (e.g. the
  configured GitHub host) on top of the scheme check.
