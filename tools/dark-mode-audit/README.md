# dark-mode-audit

Programmatic WCAG AA contrast audit for Stride pages in both light and dark
themes. Drives a real Chromium via Playwright and runs axe-core's
`color-contrast` rule per route per theme.

## Setup

```bash
cd tools/dark-mode-audit
npm install
npm run install-browsers
```

`install-browsers` downloads Chromium into Playwright's cache (~150 MB,
one-time).

## Usage

The dev server must be running (`mix phx.server`) at the base URL the auditor
hits. By default that's `http://localhost:4000`.

```bash
# Audit every marketing route in both themes
npm run audit

# Audit a specific route
node audit.mjs --routes=/pricing

# Audit just dark mode
node audit.mjs --themes=dark

# Audit against a different base URL
node audit.mjs --base-url=http://localhost:4001

# Machine-readable output for piping into other tools
node audit.mjs --json
```

The script exits non-zero when any route × theme combination has at least one
color-contrast violation, so it slots into CI when needed.

## Authenticated routes

Public marketing routes need no auth. To audit authenticated surfaces (added
by later G191 tasks: `/boards`, `/review`, `/metrics`, `/agents`, etc.),
export `STRIDE_AUDIT_SESSION` with a valid Phoenix session cookie value:

```bash
export STRIDE_AUDIT_SESSION="<value of _kanban_key cookie>"
node audit.mjs --routes=/boards,/review,/metrics
```

The cookie value can be copied out of your browser DevTools' Application
panel after signing in.

## Why this exists

Static analysis (`mix dark_mode.scan` from W899) catches hardcoded greys,
whites, hex literals, and inline `oklch()` literals. It cannot catch
theme-aware tokens that happen to produce poor contrast in dark mode, or
elements whose computed style fails WCAG AA only at runtime. The
`color-contrast` rule from axe-core handles that — it inspects every visible
element's computed foreground and background and asserts the ratio meets the
4.5:1 (small text) / 3:1 (large text) thresholds.

The two together form the W900–W909 verification pair: scanner gates source,
auditor gates rendered output.
