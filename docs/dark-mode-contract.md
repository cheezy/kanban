# Dark Mode Contract

Single source of truth for theming rules across the Stride app. Read this before
adding or changing any user-visible UI; honor it on every PR.

This document is enforced by `mix dark_mode.scan` and the wider `mix precommit`
alias. New violations fail CI. Existing violations are explicitly allow-listed
inline; do not propagate them.

## Architecture in one paragraph

The app ships two daisyUI v5 themes (`light`, `dark`) defined in
`assets/css/app.css`. The active theme is selected by a `data-theme` attribute
on `<html>`, written by the theme switch script in
`lib/kanban_web/components/layouts/{root,marketing,app_chrome}.html.heex`. A
custom Tailwind variant —
`@custom-variant dark (&:where([data-theme=dark], [data-theme=dark] *))` at
`assets/css/app.css:105` — makes the standard `dark:` Tailwind prefix work
alongside the daisyUI tokens. On top of that, a set of **Stride custom tokens**
(`--ink`, `--ink-2`, `--ink-3`, `--surface`, `--surface-2`, `--surface-sunken`,
`--line`, `--line-2`, `--stride-orange`, `--stride-violet`, `--st-ok`,
`--st-blocked`, …) is scoped to `.stride-screen` (authenticated app) and
`.stride-marketing` (public marketing surfaces), with light/dark values defined
at `assets/css/app.css:887+` and `1160+`.

Every theme-aware element must use one of these three vocabularies, never raw
greys, whites, hex literals, or `oklch()` literals inline.

## Theme activation mechanism

There is **one** activation mechanism, and both token systems key off it: the
inline bootstrap script in
`lib/kanban_web/components/layouts/{root,marketing,app_chrome}.html.heex` (kept
byte-identical across all three) **always resolves a concrete theme and writes
an explicit `data-theme` to `<html>`**.

Why "always concrete": daisyUI's `dark` theme has `prefersdark: true`, so it
honors `@media (prefers-color-scheme: dark)` on its own — but the Stride token
override (`:where([data-theme="dark"]) .stride-screen`) has **no
`prefers-color-scheme` fallback**; it only fires on an explicit
`[data-theme="dark"]`. If the bootstrap left `data-theme` unset for "system"
users (the old behavior), an OS-dark user got daisyUI-dark surfaces with
Stride-*light* tokens — an incoherent half-dark page. Resolving system → an
explicit `data-theme` makes both systems engage together.

Two attributes, two jobs:

| Attribute | Set to | Drives |
|---|---|---|
| `data-theme` | the **resolved** theme (`light` \| `dark`) | all CSS — daisyUI tokens and the Stride `:where([data-theme=dark])` override |
| `data-theme-choice` | the **user's choice** (`system` \| `light` \| `dark`) | the 3-way `theme_toggle` pill indicator (so "system" still reads as system even though `data-theme` is concrete) |

Resolution rules:

- `localStorage["phx:theme"]` stores an explicit `light`/`dark`; **absence means
  "system"**. An explicit choice always wins over and persists across reloads.
- "system" (or unset) resolves via `matchMedia("(prefers-color-scheme: dark)")`.
- A `matchMedia` `change` listener re-resolves live, so a system-mode page flips
  when the OS theme changes while it is open.
- The script must stay **inline in `<head>`** (it runs before paint to avoid a
  flash of the wrong theme) and must stay identical across the three layouts.

Error pages (`lib/kanban_web/controllers/error_html.ex`) are standalone
documents and use the same resolve-to-explicit core, minus the toggle machinery
(no pill, so no `data-theme-choice`, no `phx:set-theme` listener).

## The three token vocabularies

| Vocabulary | When to use | Examples |
|---|---|---|
| **daisyUI tokens** | Inside daisyUI components and form controls; works everywhere `data-theme` is set | `bg-base-100`, `text-base-content`, `border-base-300`, `btn-primary` |
| **Stride custom tokens** | Inside `.stride-screen` or `.stride-marketing` for app chrome, panels, typography | `var(--ink)`, `var(--surface)`, `var(--line)`, `var(--stride-orange)` |
| **Tailwind `dark:` variant** | When you need a one-off override that the daisyUI/Stride tokens don't cover | `dark:opacity-80`, `dark:shadow-none` (rare — prefer the tokens) |

### Token mapping (the substitutions that come up most)

| Hardcoded class | Replace with |
|---|---|
| `text-gray-900` | `text-base-content` (daisyUI) or `var(--ink)` (Stride) |
| `text-gray-600` | `text-base-content opacity-70` or `var(--ink-2)` |
| `text-gray-500` | `var(--ink-3)` |
| `text-gray-400` | `var(--ink-4)` |
| `bg-white` | `bg-base-100` or `var(--surface)` |
| `bg-gray-50` | `bg-base-200` or `var(--surface-2)` |
| `bg-gray-100` | `bg-base-300` or `var(--surface-sunken)` |
| `border-gray-200` | `border-base-300` or `var(--line)` |
| `border-gray-300` | `var(--line-strong)` |

### Composite gradient tokens

For the two surfaces that previously hardcoded a multi-stop gradient inline
(theme-blind), use these paired tokens instead. Each is defined in both the
light scope block and the `:where([data-theme="dark"])` override block, so a
single `var()` reference flips with the theme.

| Token | Used by | Notes |
|---|---|---|
| `var(--banner-gradient)` | Board announcement / "Important Message" banner background | Warm beige/cream sweep in light; low-lightness (~24-26% L) orange/amber/violet sweep in dark |
| `var(--banner-border)` | Same banner's outer border | `oklch(85% …)` light, `oklch(40% …)` dark — keep the orange left-accent (`var(--stride-orange)`) separate |
| `var(--loading-bar-gradient)` | Top page-loading progress bar | Brand orange→violet→orange; brand accents are identical across themes |

## Scope rules

- **`.stride-screen`** wraps every authenticated LiveView via
  `lib/kanban_web/components/layouts.ex:61`. Children should prefer Stride
  custom tokens (`var(--ink)`, `var(--surface)`).
- **`.stride-marketing`** wraps marketing pages via
  `lib/kanban_web/components/layouts/marketing.html.heex:50`. Same token
  vocabulary as `.stride-screen`.
- **`.stride-screen[data-stride-auth-frame]`** is a deliberate sub-scope at
  `assets/css/app.css:898+` that pins auth pages to a light palette regardless
  of `data-theme`. See the comment in the CSS for the rationale.
- Components rendered outside any of these scopes (rare, but it happens for
  some isolated form components) should use daisyUI tokens (`bg-base-100`,
  `text-base-content`), not Stride custom tokens — the Stride tokens are
  undefined outside the scoped selectors and will fall back to inherited
  values.

## Prohibited patterns

`mix dark_mode.scan` fails on any of the following found in `lib/kanban_web/`:

1. **Hardcoded Tailwind grey/white classes** — `text-gray-*`, `bg-gray-*`,
   `border-gray-*`, `bg-white`, `text-white`, `text-black`, `bg-black`. These
   resolve to fixed RGB values that do not flip with `data-theme`.
2. **Colored Tailwind numbered-palette utilities** — any of
   `text-/bg-/border-/from-/via-/to-/ring-/fill-/stroke-/divide-/outline-`
   paired with a numbered palette colour: `bg-yellow-100`, `text-red-600`,
   `border-indigo-200`, `ring-zinc-700`, and gradient utilities like
   `from-blue-500 via-purple-500 to-pink-500`. The palette families are
   `red orange amber yellow lime green emerald teal cyan sky blue indigo
   violet purple fuchsia pink rose slate gray zinc neutral stone`. All are
   theme-blind. Replace with daisyUI semantic tokens (`bg-base-200`,
   `text-primary`, `bg-success/30`) or the Stride `--st-*` / `--stride-*`
   tokens via arbitrary-value classes (`bg-[var(--st-done-soft)]`,
   `text-[var(--st-blocked)]`). daisyUI semantic names (`base`, `primary`,
   `secondary`, `accent`, `neutral`, `info`, `success`, `warning`, `error`)
   are NOT flagged — they are theme-aware.
3. **Arbitrary-value colour brackets** — `bg-[#fff]`, `text-[#000]`,
   `from-[#abc123]`. Hardcoded hex smuggled through Tailwind's arbitrary-value
   syntax. (Token references like `bg-[var(--st-done-soft)]` are fine.)
4. **Inline hex color literals** in `style` attributes — `style="color: #fff"`,
   `style={"background: #1a1a1a"}` (both the `style="..."` string-literal and
   the single-line `style={"..."}` expression form). Hex values are theme-blind.
5. **Inline `oklch()` literals** in `style` attributes — `style="background:
   oklch(98% 0 0)"`, `style={"background: oklch(97% 0.05 60)"}`. These are
   theme-blind unless wrapped in a variable that switches.

The scanner intentionally **does not** scan:

- `assets/css/*` — CSS files legitimately use `oklch()` and hex to *define*
  tokens.
- `docs/*` — docs reference forbidden patterns as examples.
- Test files (`*_test.exs`, files under `test/`).

### Known scanner limitations

W938 closed the multi-line blind spot: raw `oklch()` / hex literals on the
continuation lines of a multi-line **`style={[ ... ]}` list** are now flagged,
in addition to the `style="..."` and single-line `style={"..."}` forms. A
`var(--token, oklch(...))` fallback is exempt (the `var(...)` is stripped before
the raw-color check), so legitimate fallbacks do not false-positive.

Two limitations remain **by design**:

- Bare `oklch()` / hex literals **outside** any `style=` attribute are not
  flagged. Flagging them broadly would false-positive on legitimate
  `var(--token, oklch(...))` fallbacks and on intentional fixed-palette
  components (e.g. generated avatar palettes, the light-locked auth frame).
- `assets/css/app.css` is **not** scanned. It legitimately *defines* the oklch
  tokens, so a literal scan there is meaningless — the objective legibility of
  those values is measured by `mix dark_mode.contrast` instead.
- Two narrow line-based edge cases remain (both allow-listable and effectively
  absent in practice): a `var()` fallback whose colour argument itself wraps a
  nested function (e.g. `var(--ink, oklch(calc(…) …))`) is only partially
  stripped and can false-positive, and a CSS value literally containing `]}`
  ends the style-list scan one line early.

When adding a multi-line inline gradient, prefer a composite gradient token (see
the **Composite gradient tokens** table); if a fixed-palette literal is genuinely
intentional (like the auth-frame gradient), allow-list it with a real reason.

## Allow-listing

Some violations are legitimate (brand markers, fixed-contrast overlays). To
allow-list a specific line, place a `dark-mode-ignore: <reason>` comment on
the violating line OR on the immediately preceding line. The scanner accepts
all three comment shapes:

```elixir
# dark-mode-ignore: <reason>             ← Elixir (.ex files)
<%# dark-mode-ignore: <reason> %>        ← EEx (.eex files)
<!-- dark-mode-ignore: <reason> -->      ← HTML comment (.heex files)
```

`<reason>` must be a short explanation (one short sentence). Avoid "TODO" or
"FIXME" without a tracking task — if a violation needs follow-up, link the
task identifier:

```heex
<!-- dark-mode-ignore: TODO W903 — translucent overlay needs dark-mode variant -->
```

## Verification process

When adding or changing user-visible UI:

1. Run `mix dark_mode.scan` locally before committing.
2. Toggle `data-theme="dark"` in DevTools and inspect the changed surface.
3. Check WCAG AA contrast on body text (≥ 4.5:1) and large text (≥ 3:1) in
   both themes. The `browser_eval` MCP tool can read computed styles.
4. For form controls, confirm inputs, labels, placeholders, and focus rings
   are all visible in dark mode.

The longer "Dark Mode Verification Guidelines" runbook in the user's
`CLAUDE.md` (under that exact heading) covers the manual flow including
browser-eval snippets.

## See also

- `assets/css/app.css` — token definitions and the dark variant
- `lib/kanban_web/components/layouts.ex` — `.stride-screen` wrapper
- `lib/kanban_web/components/layouts/marketing.html.heex` — `.stride-marketing` wrapper
- `lib/mix/tasks/dark_mode/scan.ex` — the scanner implementation
- `test/mix/tasks/dark_mode/scan_test.exs` — scanner unit tests







