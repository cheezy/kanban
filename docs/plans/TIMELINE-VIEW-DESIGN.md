# Timeline View — Implementation Design

**Roadmap item:** *Timeline view* — "See goals and delivery targets laid out over time." ([ROADMAP](../../ROADMAP.md)).

**Status:** proposal. Nothing in this document is built yet. Every "today" statement about the code was checked against the source on 2026-10-28; file references are given as `path:line` so they can be re-checked.

The Timeline view is a new page, `/timeline`, that puts every delivery target and goal a person can see on one horizontal time axis. It answers three questions the board, the targets strip and the goal page cannot answer at a glance:

1. **When will each target land, and is that before its date?**
2. **Which goals are driving a target late?**
3. **What is in flight right now, and what has not started?**

Phase 1 is read-only and needs **no database changes**. It is built almost entirely from data and calculations that already exist for delivery targets.

**The timeline is an Organization plan feature.** It is available only to members of an Organization, and it draws only boards that belong to an Organization. Everyone else sees the standard locked-feature prompt ([§13.2](#132-organization-plan-only)).

---

## Table of contents

1. [Goals and non-goals](#1-goals-and-non-goals)
2. [Terms used in this document](#2-terms-used-in-this-document)
3. [What already exists](#3-what-already-exists)
4. [The page at a glance](#4-the-page-at-a-glance)
5. [Where the page lives](#5-where-the-page-lives)
6. [Layout in detail](#6-layout-in-detail)
7. [How bars are drawn](#7-how-bars-are-drawn)
8. [Information shown](#8-information-shown)
9. [Forecasting](#9-forecasting)
10. [Interactions](#10-interactions)
11. [Live updates](#11-live-updates)
12. [Small screens and accessibility](#12-small-screens-and-accessibility)
13. [Visibility, permissions and plans](#13-visibility-permissions-and-plans)
14. [Architecture](#14-architecture)
15. [Database changes](#15-database-changes)
16. [Performance](#16-performance)
17. [Telemetry](#17-telemetry)
18. [Translations, dark mode and docs](#18-translations-dark-mode-and-docs)
19. [Testing strategy](#19-testing-strategy)
20. [Phased delivery](#20-phased-delivery)
21. [Decisions needed](#21-decisions-needed)

---

## 1. Goals and non-goals

### Goals

- Show every visible **delivery target** as a band on a time axis, with its target date, its estimated finish, its status and how far it has slipped.
- Show every **goal** inside its target's band as a bar running from when work started to when it finished or is forecast to finish.
- Show **goals that belong to no target** in their own section, so the page covers all planned work, not only the work someone attached to a target.
- Make the cause of a late target visible: the slipped estimate, the goals furthest behind and any stalled goals.
- Stay consistent with the targets strip, the target page and `/agents`: the same status, the same percentages, the same estimate.
- Work in light and dark mode, on a phone, with a keyboard and with a screen reader.
- Be available only on the **Organization plan**, gated through `Kanban.Plans` like every other paid feature.

### Non-goals (Phase 1)

- **Editing.** Phase 1 changes nothing. Dragging a target date and planned dates on goals are Phase 3 ([§20](#20-phased-delivery)).
- **Task-level bars.** The timeline stops at goals. Work and defect tasks appear only as counts. A goal page already lists its tasks.
- **Resource planning.** No agent or person capacity lanes.
- **A new forecasting model in Phase 1.** Phase 1 reuses the existing estimate; Phase 2 replaces it ([§9](#9-forecasting)).
- **Exports.** No PDF or image export in Phase 1.

---

## 2. Terms used in this document

| Term | Meaning |
|---|---|
| Target | A `Kanban.Targets.DeliveryTarget`: a name, a `target_date`, an optional owner and description. |
| Member goal | A goal-type task whose `target_id` points at a target (`lib/kanban/tasks/task.ex:416`). Only goals can have a target. |
| Unassigned goal | A goal with no `target_id`. |
| Status | `on_track`, `at_risk`, `missed` or `complete`, calculated on every read by `Kanban.Targets.Status.derive/4` and never stored. |
| Estimate | The estimated completion date from `Kanban.Targets.Estimation.estimated_completion_date/3`. |
| Slip | Days between the target date and a later estimate (`Status.slipped?/2`). |
| Flow buckets | The five groups `Progress` sorts a goal's children into by column: done, review, doing, ready, backlog (`lib/kanban/targets/progress.ex:541-572`). |
| Window | The date range the chart currently shows. |
| Zoom | Weeks, Months or Quarters: how much time one screen width covers. |

---

## 3. What already exists

| Need | Existing code | How the timeline uses it |
|---|---|---|
| Targets with status, counts and estimate | `Kanban.Targets.list_targets_with_status_and_goals/2` (`lib/kanban/targets.ex:499`), `Progress.summarize_targets/3` (`progress.ex:227`) | The data for every target band |
| Per-goal progress and flow buckets | `Progress.goal_detail_views/1` (`progress.ex:302`) | Bar fill and counts for each goal |
| Status rules | `Status.derive/4` (`status.ex:174`): no goals → on track; all complete → complete; past `target_date` → missed; lagging by more than 15 points or estimate after date → at risk | Band colour and badge, unchanged |
| Slip check | `Status.slipped?/2` (`status.ex:199`) | Whether to draw the slip segment |
| Estimate | `Estimation.estimated_completion_date/3` (`estimation.ex:82`): remaining tasks × median lead time, counted from now | Estimated finish marker |
| Lead-time samples | `Targets.Queries.list_completed_lead_times_by_board/1` (`queries.ex:187`) | Per-goal forecast ([§9.2](#92-phase-1-per-goal-forecast)) |
| Stalled and dormant goals, active agents | `Kanban.Targets.DeliveryRollup.build/2` (`delivery_rollup.ex:147`) | Warning flags on bars |
| Why a target is at risk | `KanbanWeb.TargetRiskExplainer` (`lib/kanban_web/components/target_risk_explainer.ex`) | Text in the detail panel |
| Goal flight time | `days_in_flight/2` in `KanbanWeb.GoalLive.Show` (`lib/kanban_web/live/goal_live/show.ex:392`), which uses children's `claimed_at` | The rule for where a goal bar starts; moved into the context ([§14.2](#142-domain-modules)) |
| Board list for the current workspace | `scoped_boards/1` in `KanbanWeb.MetricsLive.Workspace` (`lib/kanban_web/live/metrics_live/workspace.ex`) | The board filter |
| Server-rendered SVG charts | `KanbanWeb.MetricsCumulativeFlow`, `MetricsThroughputChart`, `MetricsCycleTimeChart`, `PulseSparkline`, `SegmentedProgressBar` | The rendering approach: SVG in function components, `--st-*` colour tokens, no JavaScript chart library |
| Board change broadcasts | `Kanban.Tasks.Broadcaster` on `"board:#{board_id}"` (`lib/kanban/tasks/broadcaster.ex:38`) | Live updates ([§11](#11-live-updates)) |
| Sidebar | `KanbanWeb.SideNav.primary_nav_items/1` (`lib/kanban_web/components/side_nav.ex:207`) | New Timeline entry |
| Plan gating | `Kanban.Plans.check_user/3` (`lib/kanban/plans.ex:281`), `Plans.board_unlocked?/1` (`plans.ex:177`), `KanbanWeb.LockedFeature` | Organization-only access ([§13.2](#132-organization-plan-only)); `check_user/3` already emits `[:kanban, :plan, :feature_refused]` on a refusal |

**What does not exist:**

- Goals have **no start or due date**. The only dates on a goal are `inserted_at`, `completed_at`, `archived_at` and its children's timestamps.
- Targets have **no start date**. `Status` treats `inserted_at` as the start of the target's time window (`status.ex:221`).
- There is **no targets index page**. Targets appear only in the strip above `/boards` (`KanbanWeb.TargetsStrip`), on `/targets/:id` and on `/agents`.
- A target with **no member goals is invisible** in every listing, because visibility comes from its goals' boards (`lib/kanban/targets.ex:1-34`).
- Target changes are **not broadcast** on PubSub.
- Targets are **not part of any plan**: `Kanban.Plans` features are `:notifications, :audit, :sso, :workspaces, :bulk_actions, :integrations, :telemetry, :mcp` (`lib/kanban/plans.ex:89-98`). Delivery targets stay free; only the timeline is gated.

---

## 4. The page at a glance

```
 Timeline                                                         [ Chart | List ]
 Boards: All (6) ▾   Owner: Anyone ▾   Status: Active ▾   ☐ Show completed   ☐ Show archived
 ◀  Oct 1 – Jan 31  ▶   [ Today ]                              Zoom: Weeks | Months | Quarters

                      │ Oct          Nov       │      Dec              Jan
                      │                        │ today
 ▼ Q4 Launch          │                        │
   ● At risk · 62% · 18/29 · ◆ Dec 15 · est. Dec 22 (+7 days)
   ├ Billing v2       │      ██████████████░░░░│░░░░┄┄┄┄┄┄┄┄┄┄┄◆┄┄┄┄┄▶            71%
   ├ Org admin        │  ███████████████████✓  │                                 100%
   └ Audit export     │                        │░░░┄┄┄┄┄┄┄┄┄┄┄┄┄◆┄┄┄┄┄┄┄┄┄┄┄▶    12% ⚠
 ▼ Mobile beta        │                        │
   ● On track · 40% · 8/20 · ◆ Jan 20 · est. Jan 9
   └ Offline sync     │            ████████████│███░░░░░┄┄┄┄┄┄┄┄┄┄┄┄┄▶      ◆    40%
 ▼ Goals without a target
   └ Attachments      │                        │┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄  0% no estimate

  ████ done   ░░░░ in flight   ┄┄┄ forecast   ◆ target date   ▶ estimated finish   ⚠ stalled
```

The left column (names) is HTML and stays fixed while the chart scrolls horizontally inside its own container. The chart on the right is SVG. Selecting any bar or band opens a detail panel on the right side of the page ([§8.3](#83-the-detail-panel)).

---

## 5. Where the page lives

### 5.1 Route

`live "/timeline", TimelineLive.Index, :index` goes in the existing `live_session :require_authenticated_user` block in `lib/kanban_web/router.ex` (around line 365, next to `/metrics` and `/agents`). That scope pipes through `[:browser, :require_authenticated_user, :enforce_organization_two_factor]`. The page shows work from boards the user belongs to, so it must require a signed-in user and must honour the Organization's two-factor rule exactly like `/metrics`.

### 5.2 Entry points

| Where | What is added |
|---|---|
| Sidebar | A **Timeline** item after **Metrics** in `SideNav.primary_nav_items/1`, icon `hero-calendar-days`. Shown to everyone; for users without the Organization plan it opens the locked-feature prompt, so the feature can be discovered. The item itself looks the same for every user; the lock appears on the page it opens. |
| Targets strip on `/boards` | A **View timeline** link at the end of the strip, rendered only when the user has access. |
| Target page `/targets/:id` | A **See on timeline** link that opens `/timeline?target=<id>`, which scrolls to that band and highlights it. Rendered only when the user has access. |
| Goal page `/boards/:id/goals/:goal_id` | A **See on timeline** link that opens `/timeline?goal=<id>`. Rendered only when the user has access and the goal's board is an Organization board. |

"Has access" means `Plans.check_user(scope, :timeline, surface: :live_view) == :ok` — see [§13.2](#132-organization-plan-only). The in-page links are hidden rather than locked so free users are not shown a prompt on every target and goal page.

The sidebar emits these paths as plain hrefs, so the test that checks every sidebar href resolves to a route must be updated with `/timeline`.

---

## 6. Layout in detail

### 6.1 Toolbar

| Control | Behaviour |
|---|---|
| **Chart / List** | Switches between the SVG chart and an accessible list ([§12](#12-small-screens-and-accessibility)). Phone widths always show the list. |
| **Boards** | Multi-select of the boards in the current workspace, same component and rules as the workspace metrics page. All selected by default. |
| **Owner** | Anyone, Me, or a specific target owner. Filters target bands only; unassigned goals are not affected. |
| **Status** | Active (on track + at risk + missed), or any single status. Default Active. |
| **Show completed** | Includes targets whose status is complete. Off by default. |
| **Show archived** | Includes archived targets. Off by default. |
| **◀ ▶** | Moves the window back or forward by half its width. |
| **Today** | Re-centres the window so today sits a quarter of the way in from the left. |
| **Zoom** | Weeks, Months or Quarters ([§6.2](#62-time-axis-and-zoom)). |

Every control writes to the URL (`push_patch`), so a filtered timeline can be bookmarked and shared: `/timeline?zoom=months&boards[]=12&boards[]=14&status=at_risk&from=2026-10-01`.

### 6.2 Time axis and zoom

| Zoom | Window width | Major ticks | Minor ticks | Default start |
|---|---|---|---|---|
| Weeks | 8 weeks | Week starting Monday, labelled `Nov 3` | Days | Today − 2 weeks |
| Months (default) | 6 months | Month, labelled `Nov` (with year on January and at the left edge) | Weeks | Today − 1 month |
| Quarters | 18 months | Quarter, labelled `Q1 2027` | Months | Today − 3 months |

- All dates are **calendar days in the viewer's time zone** (the `:timezone` assign the metrics pages already use, falling back to `Etc/UTC`). `target_date` is a `Date` and means the end of that day.
- A **Today** line runs the full height of the chart.
- Weekends are shaded lightly on the Weeks zoom only.
- Bars that start before the window are clipped at the left edge with a small `◀` cap; bars that end after it get a `▶` cap. Clipping never changes the numbers shown in labels.

### 6.3 Target bands

Each target is a collapsible band. Its header row shows, left to right:

1. Collapse chevron.
2. Target name (links to `/targets/:id`).
3. Status badge — the same component and colours as the targets strip.
4. Percentage and `completed/total`.
5. `◆ <target date>`.
6. `est. <estimated date>`, followed by `(+N days)` in the at-risk colour when slipped, or `(N days early)` when the estimate is before the date.
7. Owner avatar.

Inside the band, one row per member goal, ordered by forecast finish (earliest first), then by name. Completed goals sort to the top so the eye reads history first, then what is left.

Collapsing a band keeps its header row and summary bar ([§7.1](#71-target-bands)) and hides its goal rows. Collapsed state is kept in the URL (`collapsed[]=<id>`), not in browser storage.

### 6.4 Goals without a target

A final band, **Goals without a target**, lists open goals on the selected boards that have no `target_id`, plus those completed inside the window. It has no status badge, no target date and no slip. Each row carries an **Add to target** link for target owners that opens the existing target form (`/targets/:id/edit`) — the timeline itself does not assign goals.

### 6.5 Targets with no goals

Today such a target is invisible everywhere. On the timeline, a target **you own** that has no goals is shown as a band with only its `◆` marker and the text "No goals yet — add goals to track progress", linking to its edit page. Other users still do not see it, because no visible board connects them to it ([§13.1](#131-who-sees-what)).

### 6.6 Empty states

| Situation | Message |
|---|---|
| User has no Organization plan | The `LockedFeature` panel for `:timeline` in place of the whole page body ([§13.2](#132-organization-plan-only)). |
| Current workspace is a personal workspace | "The timeline shows Organization boards. Switch to an Organization workspace to see it." with the workspace switcher. |
| No targets and no goals on the selected boards | "Nothing to show yet. Create a goal on a board, or create a delivery target, to see it here." with **New target** and **Go to boards** buttons. |
| Filters hide everything | "No targets or goals match these filters." with **Clear filters**. |
| Window contains no bars but some exist outside it | "Nothing in this date range." with **Jump to today**. |

---

## 7. How bars are drawn

### 7.1 Target bands

| Element | Rule |
|---|---|
| Summary bar | From the target's `inserted_at` date to its `target_date`, drawn thin and neutral behind the goal rows. This matches `Status`, which measures elapsed time from `inserted_at`. |
| `◆` target-date marker | At `target_date`, in the status colour. |
| `▶` estimate marker | At the estimate, when there is one. |
| Slip segment | When `Status.slipped?(estimate, target_date)` is true: a hatched segment from `target_date` to the estimate in the at-risk colour, labelled `+N days`. |
| Missed | When status is `missed`: the `◆` turns the missed colour and a hatched segment runs from `target_date` to today, labelled `N days overdue`. |
| Complete | The summary bar ends at the latest member goal's finish. The label reads `Delivered <date>` and adds `(N days early)` or `(N days late)`. |
| No estimate | When `Estimation` returns `nil` (no completed history on the target's boards), no `▶` is drawn and the header reads `no estimate yet`. |

### 7.2 Goal bars

| Part | Rule |
|---|---|
| **Start** | The earliest `claimed_at` among the goal's children (the same rule as `days_in_flight` on the goal page). A goal with no claimed child has **no solid part**; its forecast starts at today. |
| **Finish (done goal)** | The goal's `completed_at`; if it is nil but every child is done, the latest child `completed_at`. A `✓` sits at the end. |
| **Finish (open goal)** | Today for the solid part. A dashed **forecast** segment runs from today to the goal's estimated finish ([§9.2](#92-phase-1-per-goal-forecast)). |
| **Fill** | The solid part is split in proportion to the flow buckets: done is solid in the done colour, review and doing are lighter, ready and backlog are not drawn on the solid part (they are what the forecast covers). |
| **Percentage** | At the right of the row, from `goal_detail_views/1`. A childless goal counts as one unit, as in `Status`. |
| **Archived children** | Follow `Progress` (D124): archived-completed children count as done, other archived children are dropped. |
| **Warnings** | `⚠` for stalled, `☾` for dormant (from `DeliveryRollup`), `🔒` when any child is blocked. Each icon has text in the detail panel and an accessible label; colour is never the only signal. |
| **Past target date** | When a goal's forecast runs past its target's `◆`, the part after the `◆` is drawn in the at-risk colour. This is what shows which goals make the target late. |

### 7.3 Row geometry

- Fixed row height (32 px on desktop) so the HTML name column and the SVG rows line up without measuring.
- The SVG uses a fixed `viewBox` whose width is computed from the window and a per-day pixel size for the zoom (Weeks 24 px/day, Months 6 px/day, Quarters 2 px/day). Unlike the metrics charts it does **not** use `preserveAspectRatio="none"`, because text and markers would stretch. Labels inside the chart are kept to dates on the axis.
- The chart container scrolls horizontally on its own (`overflow-x: auto`); the page itself never scrolls sideways.

---

## 8. Information shown

### 8.1 On every target band

| Item | Source |
|---|---|
| Name, description (detail panel), owner | `DeliveryTarget` |
| Status | `Progress.summarize_targets/3` → `Status.derive/4` |
| Completed, total, percentage | `target_summary` (`progress.ex:146-153`) |
| Target date | `DeliveryTarget.target_date` |
| Estimated finish, slip or days early | `estimated_completion_date`, `Status.slipped?/2` |
| Delivered date (complete targets) | Latest member goal finish |
| Days left | `target_date − today` |
| Number of goals, number stalled | Member goals, `DeliveryRollup` |

### 8.2 On every goal row

| Item | Source |
|---|---|
| Identifier and title (links to the goal page) | Task |
| Board name (shown when more than one board is selected) | Task's column → board |
| Started | Earliest child `claimed_at` |
| Finished, or estimated finish | `completed_at`, or [§9.2](#92-phase-1-per-goal-forecast) |
| Percentage and flow-bucket counts | `goal_detail_views/1` |
| Stalled, dormant, blocked | `DeliveryRollup`, child `status` |

### 8.3 The detail panel

Selecting a bar (click, tap or Enter) opens a panel on the right. It is loaded on demand for the one selected item, so the main render stays cheap.

**For a goal:**

- Identifier, title, board, target (if any).
- Started, finished or estimated finish, days in flight.
- Counts: done, review, doing, ready, backlog, blocked.
- Time spent (sum of children's `time_spent_minutes`) and average cycle time.
- Contributors and agents currently working on it, last activity time.
- Why it is flagged: the stalled or dormant reason from `DeliveryRollup`.
- How its estimate was made: "N tasks left × median lead time X on this board" (Phase 1) or the forecast range (Phase 2).
- Links: **Open goal**, **Open board**.

**For a target:**

- Name, description, owner, target date, created date.
- Status, percentage, estimate and slip.
- The at-risk explanation, rendered by the same `TargetRiskExplainer` component used on `/agents`.
- The member goals sorted by how far past the target date their forecast runs, latest first.
- Links: **Open target**, **Edit** (owner only).

---

## 9. Forecasting

### 9.1 What the estimate does today

`Estimation.estimated_completion_date/3` takes the remaining task count for the whole target and multiplies it by the **median lead time** (`completed_at − inserted_at`) of completed tasks on the target's boards, counting forward from now. It assumes tasks are finished **one after another**, ignores complexity, ignores how many agents work in parallel and ignores weekends. It returns `nil` when there is no history.

That is adequate for a single "est." date on a card. On a timeline the error becomes visible, because every bar has a length.

### 9.2 Phase 1: per-goal forecast

To keep Phase 1 small and consistent with the rest of the app:

- **Target bands keep exactly the estimate and status they show today.** The strip, `/agents`, notifications and the timeline must never disagree.
- **Each goal** gets an estimate from the same function, using the goal's own remaining count and the lead-time samples of the goal's board: `Estimation.estimated_completion_date(lead_times[board_id], remaining_for_goal, now)`.

**Known inconsistency.** Because goals run in parallel, the latest goal estimate is usually **earlier** than the target estimate, which adds every goal's remaining work into one serial queue. Phase 1 handles this honestly rather than hiding it:

- The target's `▶` is the target estimate (the official one).
- Goal forecast segments are drawn dashed and lighter.
- The detail panel says how each date was calculated.

Phase 2 removes the inconsistency by computing both from one model.

### 9.3 Phase 2: throughput forecast with a range

Replace the serial lead-time model with a **throughput simulation**, the common approach for kanban forecasting:

1. For each board, collect completed tasks per day over the last 8 weeks (the throughput series the workspace metrics already compute).
2. To forecast N remaining tasks, run 1,000 simulations. Each simulation draws a random historical day's throughput for each future day until N tasks are done.
3. The **50th percentile** finish is the estimate (`▶`). The **85th percentile** finish is drawn as a whisker after it: "likely by Dec 22, almost certainly by Jan 6".
4. For a goal, use the board's throughput multiplied by the goal's share of that board's completions over the last 2 weeks; when there is no recent share, split the board's throughput evenly across its open goals.
5. The target's forecast is the latest of its goals' forecasts, so the band and its rows always agree.

Simulations are deterministic in tests (seeded random source) and cached per board for the duration of a render.

Adopting the new estimate changes **status** too (the at-risk rule uses it), which changes notifications sent by `TargetStatusWorker`. Phase 2 therefore swaps the estimator in **one place** — `Kanban.Targets.Progress` — so every surface changes together, and ships behind a flag until the forecasts have been compared against real outcomes. That decision is listed in [§21](#21-decisions-needed).

---

## 10. Interactions

| Interaction | Result |
|---|---|
| Click or tap a bar or band header | Opens the detail panel ([§8.3](#83-the-detail-panel)) and highlights the row. |
| Hover a bar (pointer devices) | Native SVG `<title>` tooltip: name, dates, percentage. No JavaScript. |
| Tab / Shift+Tab | Moves between bars in reading order; each bar is a focusable element with an accessible name. |
| Enter or Space on a focused bar | Opens the detail panel. |
| Escape | Closes the detail panel. |
| Collapse chevron | Collapses or expands a band; stored in the URL. |
| `?target=<id>` or `?goal=<id>` | Opens with that band or row scrolled into view, highlighted and its detail panel open. |
| Filters, zoom, ◀ ▶, Today | `push_patch` to a new URL; `handle_params/3` rebuilds the view. |

Phase 1 needs **no new JavaScript hook**. Scrolling the chart to "today" or to a focused row on load is done with `JS.dispatch` and the browser's `scrollIntoView` through an existing pattern, or skipped on the first release if that pattern does not exist.

---

## 11. Live updates

- On the connected mount, subscribe to `"board:#{board_id}"` for every selected board. `Kanban.Tasks.Broadcaster` already sends `{Kanban.Tasks, event, task}` there for every task change.
- On any such message, **coalesce**: schedule one rebuild 2 seconds later and ignore further messages until it runs. A busy board with many agents would otherwise rebuild the timeline on every move.
- **Target changes are not broadcast today.** Add a broadcast from `Kanban.Targets` on a `"targets:user:#{user_id}"` topic for each user who can see the target, or more simply a single `"targets"` topic carrying only the target id, after which each LiveView re-checks visibility. The single topic is simpler and leaks nothing, because the message carries only an id and every subscriber re-reads through its own scope. Sent on create, update, archive, unarchive, assign and unassign.
- Today's line and "days left" move at midnight in the viewer's zone: schedule a `:tick` message for the next local midnight.

---

## 12. Small screens and accessibility

### 12.1 The list view

The **List** view is both the phone layout and the accessible alternative to the chart. It is the default below 768 px, and the Chart/List toggle is hidden there.

```
 Q4 Launch                                   ● At risk
 Due Dec 15 · est. Dec 22 (+7 days) · 62% (18/29)
   Billing v2      started Oct 14 · est. Dec 18 · 71%
   Org admin       done Nov 20 · 100%
   Audit export ⚠  not started · est. Jan 2 (after target) · 12%
```

Each target is a card with its goals as rows. It carries the same information as the chart and opens the same detail panel (as a full-screen sheet on phones).

### 12.2 Chart accessibility

- The SVG has `role="img"` and an `aria-label` summarising it ("Timeline of 3 targets and 6 goals, October 2026 to January 2027"), plus a visible link "View as list".
- Every bar is a `<g>` with `tabindex="0"`, `role="button"` and an `aria-label` such as "Billing v2, started October 14, 71 percent done, estimated to finish December 18, after its target date".
- Status is never shown by colour alone: badges carry text and slip segments carry a `+N days` label.
- Colours come from the existing status tokens, which already meet the contrast rules in [the dark-mode contract](../dark-mode-contract.md).

---

## 13. Visibility, permissions and plans

### 13.1 Who sees what

The timeline adds **no new permission rules**. It only reads.

| Item | Visible when |
|---|---|
| A goal | It is on a board the user can access (board membership, or org-admin through `Workspaces.Policy`), and that board is in the current workspace and selected in the board filter. |
| A target band | At least one member goal is visible — the existing rule in `Kanban.Targets` — **or** the user owns the target ([§6.5](#65-targets-with-no-goals)). |
| A target's numbers | Exactly what `Progress` returns today for that user, so the band always matches the targets strip. |
| Member goals on boards the user cannot see | Not drawn. The band header says "N goals on boards you can't see" when that number is above zero, so the band's percentage (which covers all goals) is not confusing. |
| The detail panel | Loaded through the same scoped queries; a goal id in the URL for a goal the user cannot see renders as "not found", never as an error that confirms it exists. |

Targets are not tied to a workspace (they have no `workspace_id`). The board filter decides which goals are drawn; a target appears when any of its visible goals is on a selected board.

### 13.2 Organization plan only

The timeline is available **only on the Organization plan**. Delivery targets themselves stay free; free users keep the targets strip, the target pages and `/agents` exactly as today.

**Adding the feature to `Kanban.Plans`:**

- Add `:timeline` to `@features` (`lib/kanban/plans.ex:89`) and to the `feature()` type.
- Add `parse_feature("timeline")`.
- Add the `:timeline` label and description to `KanbanWeb.LockedFeature` and to its `@features` list (the component's `attr :feature` is restricted to that list).
- If the pricing page lists Organization features one by one, add Timeline there.

**Two checks, at two levels:**

| Check | Where | Rule |
|---|---|---|
| **User** | `TimelineLive.Index` mount, and again on every rebuild | `Plans.check_user(scope, :timeline, surface: :live_view)` must return `:ok`, which means the user is a member of an Organization. On a refusal the page renders the `LockedFeature` panel and loads no data; `check_user/3` emits the existing `[:kanban, :plan, :feature_refused]` event itself. |
| **Board** | `Kanban.Timeline.build/2` | Only boards for which `Plans.board_unlocked?/1` is true are drawn — that is, boards whose workspace belongs to an Organization. A member of an Organization who also has personal boards does not see those personal boards on the timeline. |

Both checks follow the existing enforcement switch: while `:plans_enforced` is off, `check_user/3` and `board_unlocked?/1` allow everything, exactly as they do for the other paid features.

**What follows from the board check:**

- In a **personal workspace** the page shows the "Switch to an Organization workspace" state ([§6.6](#66-empty-states)) instead of an empty chart.
- A target band appears only when at least one of its member goals is on an unlocked board the user can see. Goals on personal boards are counted in "N goals on boards you can't see", so the band's percentage still makes sense.
- An owned target with no goals is shown to its owner only when the owner passes the user check.
- The detail panel and `?goal=` / `?target=` links go through the same checks, so a goal on a personal board renders as "not found" on the timeline.

**When access ends mid-session.** If a user leaves their Organization, or a board moves out of one, while the page is open, the next rebuild re-runs both checks: the page swaps to the locked panel, or the board's rows disappear. Nothing is cached across rebuilds that could keep showing locked data.

---

## 14. Architecture

### 14.1 Overview

```
TimelineLive.Index (LiveView)
   │ handle_params → filters, window, zoom
   ▼
Kanban.Timeline.build(scope, opts)          ← single public entry point
   ├─ Kanban.Targets.list_targets_with_status_and_goals/2   (existing)
   ├─ Kanban.Timeline.Queries.goal_spans/2                  (new, batched)
   ├─ Kanban.Timeline.Queries.unassigned_goals/2            (new)
   ├─ Kanban.Timeline.Forecast.goal_estimates/3             (new, wraps Estimation)
   ├─ Kanban.Targets.DeliveryRollup.build/2                 (existing, for flags)
   └─ returns %Kanban.Timeline{bands: [...], unassigned: [...], window: ...}
   ▼
Kanban.Timeline.Layout (pure)  → x positions, ticks, clipping, row order
   ▼
KanbanWeb.Timeline.* function components → HTML name column + SVG chart / list view
```

### 14.2 Domain modules

| Module | Responsibility |
|---|---|
| `Kanban.Timeline` | The context and its single public function `build/2`. Takes `%Scope{}` first, plus `board_ids`, `owner`, `statuses`, `include_completed`, `include_archived`, `now`, `timezone`. Drops every board that fails `Plans.board_unlocked?/1` before any other query runs, and returns `{:error, :plan_required}` when `Plans.check_user(scope, :timeline, surface: :context)` refuses, so the gate holds even if a caller forgets the LiveView check. Returns plain structs; no Ecto structs leak to the view. Also `goal_detail/3` and `target_detail/3` for the detail panel, under the same checks. |
| `Kanban.Timeline.Band` | Struct: target, status, counts, target date, estimate, slip days, delivered date, hidden-goal count, rows. |
| `Kanban.Timeline.Row` | Struct: goal id, identifier, title, board, started_on, finished_on, estimate_on, buckets, percentage, flags. |
| `Kanban.Timeline.Queries` | `goal_spans/2`: for a list of goal ids, one grouped query returning the earliest child `claimed_at`, the latest child `completed_at` and the goal's own `completed_at`. `unassigned_goals/2`: open goals with no target on the given boards, plus those completed within the window. Both scoped by board ids already filtered through the scope. |
| `Kanban.Timeline.Forecast` | Phase 1: per-goal estimate via `Estimation.estimated_completion_date/3`, with lead-time samples fetched once per board through `Targets.Queries.list_completed_lead_times_by_board/1`. Phase 2: the throughput simulation. |
| `Kanban.Timeline.Layout` | Pure functions, no database: `window/3` (zoom, from, now → date range), `ticks/2`, `x_for/2` (date → pixel), `bar_geometry/2` (row → solid, forecast, slip and clip segments), `sort_rows/1`. This is where most of the unit tests live. |
| `Kanban.Timeline.GoalStats` | The goal-flight calculations moved out of `GoalLive.Show` (`days_in_flight/2` and friends at `show.ex:349-454`) so the goal page and the timeline share one implementation. The goal page then calls this module. |

Rule from `AGENTS.md`: no Ecto query in the LiveView. Everything the LiveView needs comes from `Kanban.Timeline`.

### 14.3 Web modules

| Module | Responsibility |
|---|---|
| `KanbanWeb.TimelineLive.Index` | Plan check first ([§13.2](#132-organization-plan-only)); on a refusal render only `<.locked_feature feature={:timeline} variant={:panel} />` and subscribe to nothing. Otherwise: mount (boards on both mounts, heavy read only when connected — the D120 pattern from `MetricsLive.Workspace`), `handle_params/3` for filters, PubSub handling and coalescing, detail-panel selection. Must start with `<Layouts.app flash={@flash} current_scope={@current_scope}>`. |
| `KanbanWeb.Timeline.Toolbar` | Filters, zoom, navigation, Chart/List toggle. Reuses the board selector from the workspace metrics page (extract it into a shared component if it is private today). |
| `KanbanWeb.Timeline.Chart` | Name column + SVG: axis, today line, bands, rows, markers, legend. |
| `KanbanWeb.Timeline.ListView` | The list layout ([§12.1](#121-the-list-view)). |
| `KanbanWeb.Timeline.DetailPanel` | Goal and target panels; reuses `TargetRiskExplainer` and `SegmentedProgressBar`. |

Each component stays well under the 500-line guideline; the chart is split into axis, band and row sub-components if it grows.

---

## 15. Database changes

**Phase 1: none.** `tasks.target_id` is already indexed (`priv/repo/migrations/20260706120000_create_delivery_targets.exs:22`).

Check during Phase 1 with `EXPLAIN` on realistic data whether `goal_spans/2` needs an index on `(parent_id, claimed_at)`; add it with a concurrent index migration only if the plan shows a sequential scan.

**Phase 3 (optional): planned dates on goals.**

| Column | Type | Rule |
|---|---|---|
| `tasks.planned_start_on` | `date`, null | Only on goal-type tasks |
| `tasks.planned_end_on` | `date`, null | Only on goal-type tasks; on or after `planned_start_on` |

With these, each goal row gains a thin "planned" track above its actual bar, turning the page into a plan-versus-actual chart. They would be editable on the goal form and through `PATCH /api/tasks/:id` (both need the API docs, OpenAPI and `SchemaDoc` updates the docs-coverage tests enforce).

---

## 16. Performance

- **Fixed query count.** A render runs a fixed number of queries no matter how many targets or goals there are: targets with status (existing, batched — `progress.ex:92-115`), goal spans (one grouped query), unassigned goals (one), lead-time samples (one per render), rollup flags (existing). No per-goal queries.
- **Connected-mount loading.** The disconnected render shows the toolbar and a skeleton; the data loads on the connected mount, as on the metrics page.
- **Coalesced updates.** At most one rebuild per 2 seconds per open page ([§11](#11-live-updates)).
- **Size cap.** If more than 300 goal rows match, render the first 300 by forecast finish and show "Showing 300 of N goals — narrow the boards or status filter". The cap is a module attribute, tested.
- **SVG size.** Quarters zoom over 18 months at 2 px/day is about 1,100 px wide; Weeks over 8 weeks at 24 px/day is about 1,350 px. Both are small enough to render server-side on every update.

---

## 17. Telemetry

Add one event, declared in `Kanban.Telemetry.Catalog` with its `metrics` and `persist` fields and emitted through `Kanban.Telemetry.emit/3`, as `AGENTS.md` requires:

| Event | Measurements | Metadata |
|---|---|---|
| `[:kanban, :timeline, :viewed]` | `count: 1`, `target_count`, `goal_count`, `duration` (build time, ms) | `zoom` (`weeks` / `months` / `quarters`), `view` (`chart` / `list`) |

Only allow-listed metadata keys go in (see [Telemetry](../telemetry.md) for the naming rule, the allow-list and the metric rules). No target names, goal titles or user identifiers. After the catalog changes, refresh the event reference in `docs/telemetry.md`; `test/kanban/telemetry_docs_test.exs` fails until it is.

Emit once per mount and once per filter or zoom change, not on PubSub-driven rebuilds.

---

## 18. Translations, dark mode and docs

- **Translations.** Every visible string goes through `gettext`, including axis labels, status text, aria labels and empty states. Month and weekday names come from the existing date-formatting helpers so they follow the locale. Run `mix gettext.extract --merge` and fill every locale.
- **Dark mode.** Colours come only from the existing `--st-*` and status tokens; no hardcoded Tailwind colours. Hatching uses an SVG `<pattern>` whose stroke is a token. Verified with `mix dark_mode.scan` and in the browser in both themes, as [the dark-mode contract](../dark-mode-contract.md) requires.
- **User docs.**
  - A Resources how-to, "Plan delivery with the timeline", covering reading bars, the slip segment, filters and the list view.
  - A new `docs/timeline.md` describing the page, how dates and estimates are calculated and what each marker means.
  - A `CHANGELOG.md` entry under `[Unreleased]`, mirrored in `priv/changelog/body.html`.
  - Move **Timeline view** on `ROADMAP.md` to in progress when Phase 1 starts and remove it when it ships.

---

## 19. Testing strategy

### 19.1 Unit tests

| Module | Cases |
|---|---|
| `Timeline.Layout` | Window for each zoom and `from`; ticks at month, quarter and year boundaries; `x_for` at the window edges; clipping caps for bars that start before or end after the window; weekend shading only on Weeks; time-zone edge (a `claimed_at` at 23:30 UTC that is the next day in Tokyo); DST change inside the window; empty input. |
| `Timeline.Layout.bar_geometry/2` | Done goal; open goal with a start; open goal with no claimed child (forecast only); goal with no estimate; forecast past the target date (at-risk tail); missed target; completed target early and late; childless goal. |
| `Timeline.Forecast` | Per-goal estimate matches `Estimation` for the goal's board; `nil` with no history; `nil` with nothing remaining; boards with no samples. Phase 2: seeded simulation gives stable p50/p85; zero-throughput history; goal share fallback. |
| `Timeline.GoalStats` | Same results as the current goal-page calculations on the same fixtures (moved, not rewritten). |
| `Timeline.Queries` | Earliest claim and latest completion per goal; archived children follow D124; unassigned goals exclude goals with a target; completed-in-window inclusion. |

### 19.2 Integration and LiveView tests

- Plan gating, with plans enforced (the existing `enforce_plans` test setup):
  - a user with no Organization sees the `LockedFeature` panel, no data query runs, and `[:kanban, :plan, :feature_refused]` is emitted;
  - an Organization member sees the timeline;
  - an Organization member's personal boards are not drawn, and their goals count as hidden on a shared target;
  - a personal workspace shows the "Switch to an Organization workspace" state;
  - `Kanban.Timeline.build/2` returns `{:error, :plan_required}` for a free user even when called directly;
  - removing the user from the Organization while the page is open swaps it to the locked panel on the next rebuild;
  - the "See on timeline" links are hidden for free users and shown for members;
  - the sidebar shows the Timeline item to free users and members alike, and for a free user it opens the locked panel;
  - with plans not enforced, a free user sees the timeline (the switch-off behaviour every paid feature has).
- `Kanban.Plans` and `LockedFeature` tests cover `:timeline` (`features/0`, `parse_feature/1`, the label).
- Visibility: a user sees only goals on their boards; a target with one visible goal shows with the hidden-goal count; an owned target with no goals shows to its owner only; org-admin sees what `Workspaces.Policy` allows; a goal id in the URL for an invisible goal renders "not found".
- Band numbers equal the targets strip numbers for the same user and `now` (a consistency test that guards [§9.2](#92-phase-1-per-goal-forecast)).
- Filters, zoom and navigation round-trip through the URL.
- Detail panel opens for a goal and a target, and closes on Escape.
- A broadcast on `"board:#{id}"` causes exactly one rebuild within the coalescing window.
- A target broadcast causes a rebuild and respects visibility.
- Empty states for each situation in [§6.6](#66-empty-states).
- Row cap message above the cap.
- Sidebar contains Timeline and its href resolves.
- Telemetry event fires with allow-listed metadata (`Kanban.TelemetryHelpers.attach_telemetry/2`).
- Rendering in a non-English locale (session locale set as the existing locale tests do).

### 19.3 Manual and exploratory checks

- Explore the timeline on a board with many agents moving tasks quickly, to find flicker or stale bars during coalesced updates.
- Explore zoom and window navigation around year boundaries and DST changes, to find misplaced ticks or bars.
- Explore the chart and list in dark mode and light mode, to find low-contrast hatching or markers.
- Explore on a phone width, to find horizontal page scroll or an unreachable detail panel.
- Explore with a screen reader and keyboard only, to find bars that cannot be reached or are announced without dates.

---

## 20. Phased delivery

### Phase 1 — Read-only timeline

Suggested tasks, in order:

1. Add the `:timeline` plan feature to `Kanban.Plans` and `LockedFeature` (and the pricing page if it lists features).
2. Move goal-flight calculations into `Kanban.Timeline.GoalStats` and make the goal page use it (refactor, no behaviour change).
3. `Kanban.Timeline.Layout` — pure layout functions and their tests.
4. `Kanban.Timeline.Queries` and `Forecast` (Phase 1 per-goal estimate).
5. `Kanban.Timeline.build/2`, the `Band` and `Row` structs, the plan and board checks, visibility rules including owned targets with no goals and the hidden-goal count.
6. `TimelineLive.Index` with the route, plan check and locked panel, toolbar, URL params and empty states.
7. Chart components (axis, bands, rows, markers, legend) with dark-mode and accessibility work.
8. List view and detail panel.
9. Live updates: board subscriptions, coalescing, the new targets broadcast, midnight tick, plan re-check on rebuild.
10. Sidebar item, and the access-dependent entry links from the targets strip, target page and goal page.
11. Telemetry event and `docs/telemetry.md`.
12. Docs: Resources how-to (marked as an Organization feature), `docs/timeline.md`, CHANGELOG, ROADMAP.

### Phase 2 — Better forecasts

1. Throughput simulation in `Kanban.Timeline.Forecast` with p50/p85.
2. Range whiskers on bars and the forecast explanation in the detail panel.
3. Behind a flag: switch `Kanban.Targets.Progress` to the new estimator so status, the strip, `/agents`, notifications and the timeline all move together. Compare old and new estimates against actual delivery for a few weeks before turning the flag on.

### Phase 3 — Planning

1. Planned start and end dates on goals ([§15](#15-database-changes)), editable in the goal form and the API, drawn as a planned track.
2. Drag the `◆` to change a target date (owners only), through `Targets.update_target/3`, with undo.
3. Dependency arrows between goals: goal-level `dependencies` plus child tasks that depend on another goal's tasks, aggregated to one arrow per goal pair. Off by default.
4. Export the current view as PDF, using the same approach as the metrics PDF export.

---

## 21. Decisions needed

| # | Decision | Recommendation |
|---|---|---|
| 1 | Goal dates: work them out from activity (Phase 1) or add planned dates now? | Work them out first; add planned dates in Phase 3 if teams ask for plan-versus-actual. |
| 2 | Forecast: ship Phase 1 on the existing estimate, or wait for the throughput model? | Ship on the existing estimate with the consistency rules in [§9.2](#92-phase-1-per-goal-forecast); Phase 2 follows. |
| 3 | When Phase 2 lands, should status and notifications switch to the new estimate? | Yes, in one place, behind a flag, after comparing against real outcomes. |
| 4 | Show owned targets with no goals on the timeline? | Yes, to the owner only. |
| 5 | Read-only or editable in the first release? | Read-only. |
| 6 | Plan: free for everyone, or Organization only? | **Decided: Organization only** ([§13.2](#132-organization-plan-only)). **Decided:** the sidebar item is shown to free users too and opens the locked prompt, so the feature can be discovered. |
| 7 | Scope: the current workspace's boards, or all boards the user can see? | Current workspace, with the board filter, matching `/metrics`. |
| 8 | Include unassigned goals? | Yes, in their own band, so the page shows all planned work. |
| 9 | Target-change broadcast: one `"targets"` topic carrying ids, or per-user topics? | One topic carrying only ids; each page re-reads through its own scope. |
| 10 | Row cap. | 300 rows, with a message to narrow the filters. |
