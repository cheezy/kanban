# Responsive Audit Baseline

Single source of truth for responsive layout rules across the Stride app. Read
this before auditing or changing the layout of any page; honor it on every
responsive PR. It is the responsive counterpart to `docs/dark-mode-contract.md`
— where that document anchors theming work, this one anchors responsive work so
each per-page audit applies the **same** breakpoints, the **same** test widths,
and the **same** checklist instead of inventing its own.

There is no automated scanner for responsive correctness today (unlike
`mix dark_mode.scan`). Responsive verification is therefore a **manual visual
pass at the canonical test widths** below — the per-page checklist is the
contract that pass must satisfy. A page is not "responsive-audited" until every
checklist item has been confirmed at mobile, tablet, and desktop widths.

## Architecture in one paragraph

Responsive behavior in the app comes from **two** layers. Most of it is
**Tailwind responsive prefix utilities** (`sm:`, `md:`, `lg:`) applied directly
in HEEX templates — the default and preferred mechanism. A smaller set of
**custom `@media` rules in `assets/css/app.css`** handles structural overrides
that a utility prefix cannot express cleanly — they target named classes
(`board-header-bar`, `task-detail-layout`, `task-detail-aside`) and use
`!important` to beat inline declarations. The split is the convention:
**Tailwind prefixes for everything; custom CSS `@media` only when an override
must defeat an inline style or restructure a scoped layout.** The Tailwind
breakpoints and the custom `@media` breakpoints are deliberately aligned to the
same scale (640 / 768 / 1024), so the two layers reinforce one breakpoint ladder
rather than competing.

## The breakpoint ladder (one scale, two mechanisms)

The app uses Tailwind's default `sm`/`md`/`lg` scale. **Do not invent new
breakpoints** — every responsive rule keys off one of these three values, in
either the Tailwind-prefix vocabulary or the custom-CSS `@media` vocabulary.

| Breakpoint | Tailwind prefix | Direction | Mechanism | Role |
|---|---|---|---|---|
| 640px | `sm:` | min-width | Tailwind | Marketing nav/hero/features padding step-up, brand name reveal, hero typography |
| 768px | `md:` | min-width | Tailwind | The primary app pivot — sidebar static vs drawer, snap-scroll off, master-detail side-by-side, grids widen |
| 1024px | `lg:` | min-width | Tailwind | Marketing 2-column layouts, final padding tier, hero illustration reveal |
| `max-width: 767px` | — | max-width | custom `@media` | Global body font bump (`14.5px`) on narrow mobile |
| `max-width: 768px` | — | max-width | custom `@media` | `.stride-screen` board header/tabs density |
| `max-width: 1023px` | — | max-width | custom `@media` | `.stride-screen` task-detail layout stacking (below `lg`) |

> **768px is the master pivot.** It is where the authenticated app transforms
> from a single-column mobile shell (off-canvas drawer, one snap-scrolled column
> at a time, stacked master-detail) into the desktop layout. The sidebar hook's
> internal `MD_BREAKPOINT_PX = 768` constant and the `md:` Tailwind prefix must
> stay in agreement — if you move one, move the other.

The off-by-one between `max-width: 767px` (font) and `max-width: 768px` (board
chrome) is intentional: the font rule excludes the 768px boundary itself so it
does not overlap the chrome-density rule.

## Canonical test widths

Every audit verifies at these widths. They bracket the breakpoints above so each
layer of the ladder is exercised at least once.

| Label | Width | Represents | Exercises |
|---|---|---|---|
| Mobile | **375px** | iPhone (small/standard phone) | Below all `min-width` breakpoints; drawer, single snap column, stacked detail |
| Tablet | **768px** | iPad portrait | The `md:` boundary — desktop pivot just engaging; task detail still stacked (`< 1024`) |
| Desktop | **1280px** | Laptop / standard desktop | Above all breakpoints; full multi-column layouts |

Two edge widths to spot-check when a page looks fragile, but not part of the
standard three:

- **320px** — very narrow phones; confirm nothing overflows or clips at the
  floor.
- **1920px** — large desktop; confirm content does not stretch uncomfortably or
  leave the layout stranded.

## The per-page checklist

Run this against every page at all three canonical widths. A page passes only
when every item holds at mobile, tablet, **and** desktop.

| # | Concern | What to confirm |
|---|---|---|
| 1 | **Overflow** | No horizontal scrollbar except where intentional (the board's snap-scroll columns, metrics charts). Nothing clips off the right edge. Long titles/labels wrap or truncate, never push the layout wide. |
| 2 | **Stacking** | Multi-column layouts collapse to a sensible vertical order on mobile. Master-detail panels show list-then-detail, not a squeezed two-up. Reading order still makes sense once stacked. |
| 3 | **Touch targets** | Interactive controls (buttons, links, toggles, the hamburger) are large enough to tap on mobile and are not crowded together. The drawer toggle and snap indicators are reachable. |
| 4 | **Readability** | Body text stays legible (the `14.5px` mobile bump applies); headings scale down without overflowing; nothing is so small it requires zoom. Line lengths stay comfortable. |
| 5 | **Dark mode** | The page reads correctly in **both** light and dark at every width — responsive and dark-mode regressions often hide at the same breakpoint. Defer to `docs/dark-mode-contract.md` for the token rules; here, just confirm both themes survive the layout change. |

## Existing responsive primitives to reuse

Before building a new responsive pattern, reach for one of these already in the
codebase. Reusing them keeps audits consistent and avoids reinventing behavior
that is already tested in production.

| Primitive | Where it lives | What it does |
|---|---|---|
| **Sidebar drawer** | `assets/js/hooks/sidebar.js` (hook `Sidebar` on `#app-shell` in `lib/kanban_web/components/layouts.ex`) | Below 768px the sidebar is an off-canvas drawer (`-translate-x-full` → `translate-x-0`), opened by the `[data-sidebar-toggle]` hamburger, with backdrop, focus trap, Escape/backdrop/link-click close, and auto-close on resize past 768px. Static `md:` sidebar above. |
| **Snap-scroll columns** | `lib/kanban_web/live/board_live/show.html.heex` (`#columns`) + `assets/js/hooks/snap_indicator.js` | Mobile: `flex overflow-x-auto snap-x snap-mandatory` container with each column `snap-start w-[calc(100vw-2rem)]` so exactly one column is in view; an `IntersectionObserver`-driven dot strip (`#snap-indicator`, `md:hidden`) shows position. Desktop: `md:snap-none`, columns become `md:flex-1 md:min-w-[288px]`. |
| **Mobile-first master-detail** | `lib/kanban_web/live/review_live.ex`, `lib/kanban_web/live/agents_live.ex` | List pane `w-full md:w-[380px] md:flex-shrink-0`, detail pane `flex-1 min-w-0`; on mobile the unselected pane is `hidden`, with a `md:hidden` back button. Use this for any list-plus-detail screen. |
| **Responsive container padding ladder** | `assets/css/app.css` (`.nav-container`, `.hero-container`, `.features-container`) | The shared 3-step padding scale: `1rem` mobile → `1.5rem` at `sm` → `2rem` at `lg`. The marketing-scope container convention. |
| **Mismatched overflow escape hatch** | `assets/css/app.css` (`.stride-screen #columns`: `overflow-x: auto; overflow-y: visible`) | Lets tooltip bubbles escape the horizontally-scrolling board vertically. Pair with `overflow: visible` on the card `<article>`. Reuse when a scroll container must still let overlays bleed out one axis. |
| **Tailwind responsive grid/flex utilities** | App-wide (e.g. `grid-cols-1 md:grid-cols-2 lg:grid-cols-3`, `grid-cols-2 md:grid-cols-4`, `flex flex-col md:flex-row`, `flex flex-col sm:flex-row`) | The default mechanism for column counts and axis flips. Prefer these prefix utilities over custom CSS for any new responsive layout. |
| **Conditional reveal/hide** | `nav_components.ex`, `marketing_components.ex` | `hidden sm:block` (brand name), `hidden md:block` (user badge), `hidden md:flex` / `md:hidden` (desktop links vs native `<details>` mobile menu), `overflow-x-auto md:overflow-x-visible` with a fade mask for the marketing mini-board. Use for show-on-desktop / show-on-mobile toggles. |

## Prohibited patterns

These undermine the single-ladder convention. Avoid them in responsive work:

1. **Inventing new breakpoints.** Do not add `@media` queries at arbitrary
   widths or arbitrary Tailwind `[width:...]` breakpoints. Use the `sm` / `md` /
   `lg` (640 / 768 / 1024) scale only. A new breakpoint fragments the ladder and
   every future audit has to account for it.
2. **Reaching for custom CSS `@media` when a Tailwind prefix would do.** Custom
   `@media` rules are reserved for structural overrides that defeat inline
   declarations or restructure a scoped layout. For column counts, axis flips,
   padding, and show/hide, use the prefix utilities.
3. **Reinventing an existing primitive.** Do not hand-roll a drawer, a
   horizontal snap scroller, or a master-detail split when the primitives above
   already exist. Mismatched implementations make audits inconsistent.
4. **Desyncing the 768px pivot.** Do not change the sidebar hook's
   `MD_BREAKPOINT_PX`, the `md:` layout assumptions, or the board snap behavior
   in isolation — they form one pivot and must move together.
5. **Auditing at non-canonical widths only.** A page checked at a random window
   size is not audited. Confirm at 375 / 768 / 1280 so results are comparable
   across pages.

## Definition of done

A responsive change or page audit is **done** only when ALL of the following
hold — not just the first:

1. **The page passes the per-page checklist at all three canonical widths** —
   overflow, stacking, touch targets, readability, and dark mode confirmed at
   375px, 768px, and 1280px.
2. **No new breakpoints were introduced** — the change uses the `sm`/`md`/`lg`
   ladder and reuses existing primitives where one applies.
3. **Both themes were verified visually at each width** — responsive and
   dark-mode regressions cluster at the same breakpoints, so the visual pass
   covers light and dark together (the dark-mode rules themselves live in
   `docs/dark-mode-contract.md`).

"It looked fine on my screen" is **necessary but not sufficient** — a single
window width does not exercise the ladder. Confirm the bracket.

## Verification process

When adding or changing the layout of a page:

1. Open the page and set the viewport to **375px**. Walk the per-page checklist
   top to bottom. Note any overflow, clipping, or unreachable controls.
2. Resize to **768px**. Confirm the desktop pivot engages cleanly (drawer →
   static sidebar, snap-scroll → flex columns, stacked → side-by-side where the
   page does so at `md`). Re-walk the checklist.
3. Resize to **1280px**. Confirm full multi-column layouts and that nothing is
   stranded or over-stretched. Re-walk the checklist.
4. Toggle dark mode at one of the widths and confirm the layout survives in both
   themes (see `docs/dark-mode-contract.md`).
5. If the page felt fragile at any step, spot-check **320px** and **1920px**.

## See also

- `docs/dark-mode-contract.md` — the theming counterpart to this document
- `assets/css/app.css` — the custom `@media` rules and the marketing padding ladder
- `assets/js/hooks/sidebar.js` — the sidebar drawer primitive (`MD_BREAKPOINT_PX = 768`)
- `assets/js/hooks/snap_indicator.js` — the snap-scroll column indicator
- `lib/kanban_web/live/board_live/show.html.heex` — the snap-scroll board columns
- `lib/kanban_web/live/review_live.ex` — the mobile-first master-detail pattern
- `lib/kanban_web/live/agents_live.ex` — the master-detail pattern (Agents view)
- `lib/kanban_web/components/layouts.ex` — the `#app-shell` sidebar mount point
