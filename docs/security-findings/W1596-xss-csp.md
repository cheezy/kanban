# Security Findings — XSS, Output Encoding & CSP (W1596)

> Domain 5 of the comprehensive security review (G309). Manual analysis plus an
> independent `stride-security-review` full-file pass.
>
> **Verdict: strong; no stored XSS.** 0 critical · 0 high · 0 medium · 2 low
> (CSP defense-in-depth) · 3 boundaries verified clean.

## Surface reviewed

`plugs/csp_nonce.ex`, router secure headers, `components/review_report_panel.ex`,
`components/review_diff_panel.ex`, `live/resources_live/{show,components}.ex`,
`components/task_visuals.ex`, `review_report_helpers.ex`, MDEx markdown rendering.

## D113 — CSP hardening (2 low findings, filed together)

Both in `csp_nonce.ex` `build_policy/1`, both defense-in-depth (no live exploit —
`script-src` is nonce-based and free of `unsafe-inline`, and the HTML-injection
sinks are defended):

1. **`style-src 'unsafe-inline'`** remains — a style payload from any future
   HTML/attribute injection could do CSS-based exfiltration or clickjacking.
2. **Missing `base-uri` / `form-action` / `object-src`** — `base-uri` doesn't
   fall back to `default-src`, so an injected `<base>` tag could rehome relative
   URLs to an attacker origin.

**Fix:** add `base-uri 'self'; form-action 'self'; object-src 'none'`, and migrate
the handful of dynamic inline styles (priority dot, status pill, drag positioning,
loading bar) to CSS custom properties / nonce'd `<style>` so `style-src` can drop
`unsafe-inline`.

## Verified-clean boundaries

- **Stored XSS via `review_report` markdown** — rendered through `raw/1` in
  `review_report_panel.ex:119`, but `MDEx.to_html/1` runs with its **secure default
  `unsafe: false`** (confirmed in the vendored dep), which escapes raw HTML and
  neutralizes `javascript:`/`data:` link schemes. Reviewer `summary`/`description`
  fields use auto-escaped `{...}` interpolation, not `raw`. **Residual guard:** never
  pass `unsafe: true` to MDEx on this untrusted input — worth a regression test.
- **`script-src`** is nonce-based, free of `unsafe-inline`; router placeholder +
  last-write-wins overwrite is sound; `put_secure_browser_headers` applied.
- **`review_diff_panel.ex`** diff text passes through `html_escape/1`; the `class`
  attribute is an internal add/del/ctx classification, not user input.
- **`resources_live` markdown** escapes HTML first, then applies regex transforms,
  with a `safe_url?/1` scheme allow-list; content source is static `HowToData`.
