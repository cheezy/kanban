# Dark Mode Contract

Single source of truth for theming rules across the Stride app. Read this before
adding or changing any user-visible UI; honor it on every PR.

This document is enforced by **two** mix tasks:

- `mix dark_mode.scan` catches theme-**blind** patterns (hardcoded greys/whites,
  numbered-palette utilities, raw hex/`oklch()` in `style`). It runs in
  `mix precommit`.
- `mix dark_mode.contrast` measures whether the resulting colors are actually
  **legible** — it parses the token palette and computes WCAG contrast for both
  themes. Its enforcing mode is wired into `mix precommit` by the lock-in task.

A green scanner alone does **not** mean dark mode is correct: the scanner only
checks that you used *tokens*, not that the tokens are *readable*. That gap is
exactly why earlier "dark-mode-fixed" goals shipped an illegible UI. See
**Definition of done** below. New violations fail CI; existing exceptions are
allow-listed inline — do not propagate them.

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

## The unified dark palette (one ladder, two vocabularies)

The G202 work re-tuned dark mode into **one coherent palette**. The daisyUI base
tokens and the Stride surface tokens now resolve to the **same** dark values, so
`bg-base-100` and `var(--surface)` paint identically — there is no longer a
"daisyUI surface" and a separate, brighter "Stride surface" fighting each other.
Keep them aligned; if you re-tune one, re-tune its twin (and re-run
`mix dark_mode.contrast`).

**Dark surface ladder** (lightness encodes elevation — recessed is darkest,
raised is lightest; hue 270 / chroma 0.005 throughout):

| Role | Stride token | daisyUI twin | Dark L |
|---|---|---|---|
| Recessed wells / sunken | `var(--surface-sunken)` | `bg-base-300` | 12% |
| Page canvas | `var(--bg)` | `bg-base-200` | 16% |
| Raised cards / components | `var(--surface)` | `bg-base-100` | 20% |
| Nested / highest surface | `var(--surface-2)` | *(none)* | 24% |

**Dark ink** (all clear WCAG AA on every surface above): `var(--ink)` 95% ·
`var(--ink-2)` 82% · `var(--ink-3)` 75% · `var(--ink-4)` 66%. daisyUI
`text-base-content` = `var(--ink)` (95%).

**Dark borders** (raised so edges are visible, subtle not harsh):
`var(--line)` 38% · `var(--line-2)` 44% · `var(--line-strong)` 50%.

**Dark brand accents** (brightened for vibrancy on dark; also feed
`--loading-bar-gradient`): `var(--stride-orange)` 72% · `var(--stride-violet)`
68%.

**Dark priority dots** (four *distinct* lightnesses so they are differentiable
by brightness as well as hue): critical 64% · high 72% · medium 80% · low 74%.

The light palette is unchanged by this work; the dark overrides live in the
`:where([data-theme="dark"]) .stride-marketing, .stride-screen` block and the
daisyUI `@plugin "…" { name: "dark"; … }` block in `assets/css/app.css`.

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

### Choosing daisyUI base-\* vs Stride `--surface`/`--ink`

Because the two ladders now **coincide** (see the table above), the choice is
about scope and consistency, not color:

- Inside `.stride-screen` / `.stride-marketing`, prefer the **Stride tokens**
  (`var(--surface)`, `var(--ink)`, `var(--line)`) — they carry the full design
  ladder (including `--surface-2` and `--ink-2..4`, which have no daisyUI twin)
  and match the surrounding app chrome.
- For **daisyUI components/form controls**, or anything rendered **outside** a
  Stride scope, use the **daisyUI tokens** (`bg-base-100`, `text-base-content`,
  `border-base-300`) — the `var(--*)` tokens are undefined out there.
- **Match elevation, not just "a surface."** Page canvas = `--bg` / `bg-base-200`;
  raised card = `--surface` / `bg-base-100`; recessed well or column = sunken /
  `bg-base-300`; a nested surface that must sit *above* a card = `--surface-2`.
  A surface that is one tier too light reads as a "bright box" in dark — the
  exact regression D48 fixed.
- When an element needs a **different dark elevation without changing light**,
  use a `dark:` variant of the daisyUI tier (e.g. `bg-base-100 dark:bg-base-200`)
  — the base classes are theme-coupled, so a bare swap would move light too.

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

## Definition of done

Dark mode for a change is **done** only when ALL THREE hold — not just the first:

1. **`mix dark_mode.scan` passes** — no theme-blind patterns (you used tokens).
2. **`mix dark_mode.contrast` passes** — the tokens you used are objectively
   legible: every canonical text-on-surface, border, status, brand, and daisyUI
   pair clears its threshold in BOTH light and dark (run `--enforce` for a
   non-zero exit on any failure). Scanner-green with contrast-red means you used
   the right *vocabulary* but the wrong *values* — that is still broken.
3. **A human verified both themes visually** — toggle light AND dark (and try
   OS-dark with the in-app theme on "system") and confirm the changed surfaces
   read coherently: correct elevation, visible borders, legible text, on-palette
   accents. The contrast task cannot catch layout/elevation mistakes — a
   correctly-*colored* surface placed at the wrong elevation tier still looks
   wrong (the "bright box" class of bug).

"The scanner passed" is **necessary but not sufficient**. Treating it as
sufficient is what shipped the illegible dark mode this contract now guards
against.

## Verification process

When adding or changing user-visible UI:

1. Run `mix dark_mode.scan` **and** `mix dark_mode.contrast` locally before
   committing (the scanner is in `mix precommit`; the contrast validator's
   enforcing mode is wired in by the lock-in task).
2. Toggle `data-theme="dark"` in DevTools and inspect the changed surface; also
   confirm light is unchanged.
3. Read the `mix dark_mode.contrast` report for the pairs your change touches;
   for any new token pair, confirm it clears AA (text, ≥ 4.5:1) / the graphical
   floor (≥ 3:1) / the border floor (≥ 1.5:1) in both themes.
4. For form controls, confirm inputs, labels, placeholders, and focus rings
   are all visible in dark mode.

The longer "Dark Mode Verification Guidelines" runbook in the user's
`CLAUDE.md` (under that exact heading) covers the manual flow including
browser-eval snippets.

## See also

- `assets/css/app.css` — token definitions and the dark variant
- `lib/kanban_web/components/layouts.ex` — `.stride-screen` wrapper
- `lib/kanban_web/components/layouts/marketing.html.heex` — `.stride-marketing` wrapper
- `lib/mix/tasks/dark_mode/scan.ex` — the pattern scanner implementation
- `test/mix/tasks/dark_mode/scan_test.exs` — scanner unit tests
- `lib/mix/tasks/dark_mode/contrast.ex` — the WCAG contrast validator
- `test/mix/tasks/dark_mode/contrast_test.exs` — contrast validator tests







