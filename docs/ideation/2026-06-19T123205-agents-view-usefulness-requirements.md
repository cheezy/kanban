# Make the Agents view useful for ops, product, and developers

*Date: 2026-06-19 12:32*
*Session: 2026-06-19T123205-agents-view-usefulness*

## Problem
The `/agents` view today shows what agents are doing but not *who* is doing it — work is identified only by agent model name (e.g. "Claude Opus 4.8"), never tied to the human owner or operator behind it. Beyond that, fleet health isn't legible: there is an event feed and per-agent stats, but no answer to "is the fleet healthy and productive right now?" And the single, undifferentiated page serves none of its three audiences — ops, product managers, and developers — well, so each leaves without the specific thing they came for. The page was never fully fleshed out and adds little value in its present form; that is the case for acting now rather than later.

## Goal
A live operational dashboard for the agent fleet that surfaces the *person* behind each agent — not just the agent model — and lets ops, product managers, and developers each get the answer they came for, fast.

## Success metrics
- **leading indicators** (observable while the work is in flight, predict the outcome):
  - Daily active viewers of `/agents` — people actually open the page and return to it.
- **lagging indicators** (the outcome itself, observable only after it has occurred):
  - Sustained weekly adoption — a stable share of ops/PM/dev users return week over week for a month-plus (retention, not a launch-week spike).
  - Stuck-agent detection time drops — median time from an agent stalling or sitting in review to a human noticing falls measurably (e.g. from a day to under an hour).

## Assumptions
*Ordered highest to lowest risk; the riskiest entry is marked `(R)`.*
- People will actually adopt the page and rely on it day to day; if they keep asking in Slack/standups instead, no amount of polish delivers value. (R)
- Each agent can be reliably linked to a human owner/operator, so the page can show the person and not just the agent model — this linkage may not be captured well today.
- Ops, product managers, and developers genuinely want distinct information from this page that we can identify and serve in one place.
- The data needed to serve all three personas mostly already exists (tasks, claims, reviews, PubSub presence) and is trustworthy enough once the known display bugs (D83 status mislabeling, D84 sort order, D85 stat overlap) are fixed.

## Constraints
- Stay within the existing `/agents` LiveView and the current stride-screen design system and tokens — no separate app or standalone analytics tool.
- Real-time and access-scoped — keep the live PubSub updates and the board/scope access rules, and work in both light and dark mode.
- Read-only over existing task data — must not require schema or task-lifecycle/workflow changes to Stride to function.

## Non-goals
- Not a full BI/analytics product — no custom report builder, dashboards-as-code, or exportable charts.
- Not full agent transcripts — won't show conversation logs or token-level detail per agent on this page.
- Not agent control — view-only; no starting, stopping, or reassigning agents from this page.

## Outcome
After this ships, `/agents` is where ops, product managers, and developers each go first and get their answer fast: ops sees fleet health at a glance (who is working, waiting, stuck, idle — and who owns them), product managers see throughput and quality trends, and developers can drill into a single agent's activity, claims, and current work. It is a page people open daily and trust, not one they write off.

## Open questions
- How is the "person behind the agent" captured today, and what is the smallest reliable way to surface owner/operator alongside the agent?
- What exactly differs between the ops, PM, and developer views — separate tabs, a single layered page, or role-aware emphasis?
- Which trends matter enough to PMs to be worth showing (throughput, success rate, cycle time)?

## Decomposition seams
This initiative is intentionally broad; it is meant to ship as **multiple independent Stride goals, scheduled one at a time**. Each slice below stands on its own and can be decomposed separately — e.g. run `/stride-ideation:stridify <this doc> --goal <n>` once per slice.

1. **Owner linkage** — map each agent to its human owner/operator and surface the person alongside the agent name across the roster and activity feed. Foundational for the "show the person, not just the agent" goal.
2. **Fleet health at a glance** — a rollup that makes "is the fleet healthy right now?" legible: who is working / waiting / stuck / idle, with counts and emphasis on stuck or idle agents. Depends on first correcting the known display bugs (D83 status mislabeling, D84 sort order, D85 stat overlap) so the data can be trusted.
3. **Product-manager throughput & quality trends** — aggregate and time-series views of throughput, success rate, and cycle time for the PM persona.
4. **Developer per-agent drill-down** — a detail view to inspect a single agent's activity, claims, failures, and current work for the developer persona.
