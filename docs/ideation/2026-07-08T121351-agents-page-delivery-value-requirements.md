# Enhance the /agents page to be genuinely useful to delivery organizations

*Date: 2026-07-08 12:13*
*Session: 2026-07-08T121351-agents-page-delivery-value*

## Problem
The workspace-level `/agents` page today is passive telemetry: it derives agent state (roster, activity feed, throughput, success rate) from Task records and displays it, but it drives no decision and offers no action — a delivery lead looks at it, nods, and closes the tab. Worse, the metrics it shows are disconnected from the delivery outcomes the organization is actually measured on (targets, deadlines, delivered value). As AI-agent usage scales across the workspace, this "flying blind" becomes a growing, concrete cost — which is what makes it worth solving now rather than later.

## Goal
Transform `/agents` from a passive telemetry dashboard into a delivery-oriented control surface: connect agent activity to delivery outcomes and let the people running delivery act on what they see. The primary user is the delivery lead / engineering manager accountable for hitting targets; the fleet operator and the upward-reporting leader are served as secondary audiences.

## Success metrics
- **leading indicators** (observable while the work is in flight, predict the outcome):
  - Delivery leads actually use it — weekly-active delivery leads and repeat visits.
  - Interventions initiated from the page (reassign, reprioritize) per week.
- **lagging indicators** (the outcome itself, observable only after it has occurred):
  - Fleet task success rate and completed-throughput per agent trend upward over time.
  - Leadership can confidently answer "is the AI investment paying off?" — measured by survey and continued/expanded investment.

## Assumptions
*Ordered highest to lowest risk; the riskiest is marked `(R)`. Each carries the challenge-gate confidence rating — `(high)` / `(medium)` / `(low)`.*
- Delivery leads want a dedicated agent surface and will fold it into their routine rather than staying in the board, standups, and Slack. (R) (low)
- Reprioritizing a goal actually changes what agents work next — i.e., the task-claim order (`GET /api/tasks/next`) respects priority. If it does not, the Reprioritize action changes a number but not fleet behavior (it is theater). (low)
- Reassigning a goal's not-started children is safe against the agents' auto-claim: a task claimed between the confirmation dialog and the write is detected and skipped rather than yanked from an agent mid-flight. (low)
- The interventions that actually move outcomes can be initiated from inside Stride, not only outside it. (medium)
- "Target owner or board owner" is the right actor set for who may intervene — it matches who actually runs delivery, and a first-class board-owner concept exists (or a clear equivalent). (medium)
- Serving three personas (lead / operator / leader) from one surface won't dilute the primary delivery-lead experience. (medium)
- Agent activity can be meaningfully tied to delivery outcomes even though Stride models tasks/boards but not sprints, deadlines, or targets. (low)
- The AI fleet is scaling enough that "flying blind" is a real, present pain worth solving now. (high)
- Existing derived data plus new persistence (permitted) is rich enough to power delivery-relevant views. (high)

## Constraints
- Deliberately unconstrained: a full redesign and new data persistence (new tables/models) are explicitly permitted if needed to achieve the objectives — the current read-only-derived architecture is *not* a boundary.
- Preserve existing per-user board access scoping (a user sees only agents/tasks on boards they can access).
- Remain within the Stride Phoenix application (no separate service).
- In-page write actions run through the existing context modules (`Kanban.Tasks` / `Kanban.Targets`), never Ecto in the LiveView, and honor board access scoping on the write path exactly as reads do.

## Non-goals
- Not tracking or managing human contributors' work — this surface is about AI agents.
- Not pivoting to a board-embedded or alert-first design in this iteration — those alternatives were considered and deferred (see Design challenge), not adopted now.
- In-page interventions (seam 3) ship as **Reassign + Reprioritize only** this iteration; **Unblock** and **Nudge** are explicitly deferred (recorded as live options to revisit), not built now.
- Not reassigning in-progress or completed work — Reassign touches only a goal and its not-started (Backlog/Ready, unclaimed) children.

## Outcome
A delivery lead opening `/agents` (or alerted by it) can, in one place: see whether delivery is on track with agent work tied to real outcomes; catch stuck, failing, or drifting agents before they cost a deadline; and act directly — reassign a goal's not-started work to a different owner, or reprioritize it — instead of only observing. The page has shifted from a report you glance at to a surface you manage delivery from.

## Sketch
*Phase 1 (target-modeling foundation) design — locked during refinement on 2026-07-06.*

A **Delivery Target** is a new **workspace-level** entity that groups goals under a target delivery date, surfaced as a strip on the boards page (`/boards`), mirroring the existing per-board goals strip (`goals_strip`). Clicking a target reveals its member goals (reusing `goal_card` and the existing `/boards/:id/goals/:goal_id` drill-down).

- **New `delivery_targets` table:** `name`, `target_date` (the target date), `description`, `owner_id` (belongs_to user), timestamps. No stored baseline/history in v1.
- **Membership — one target per goal:** a nullable `target_id` FK on the `tasks` row, changeset-guarded to `type: :goal`, `ON DELETE SET NULL`, indexed. The grouping key rides on the goal; the date/owner/description live on the target.
- **Derived on-track status** (no stored column), computed at read time from member goals' existing children rollup vs `target_date`: **Complete** (all member goals done) · **Missed** (`today > target_date` and not complete) · **At-risk** (% of goal-work completed lags % of calendar time elapsed from creation → `target_date` beyond a threshold) · **On-track** (everything else).
- **Access scoping:** targets span boards, but each viewer sees only member goals on boards they can access (`BoardScope`, the same IDOR guard `Kanban.Tasks.Goals` uses). A user sees a target only if they own it or can access at least one member goal's board.
- **Boundaries:** all reads/writes live in a new `Kanban.Targets` context (no Ecto in the LiveView); all UI text via gettext.

*Phase 2 (delivery-outcome views) design — locked during refinement on 2026-07-06; shipped as goal G308.*

The `/agents` page is **restructured in place** from agent-centric to **delivery-centric**: it opens on a target-health band, with the agent roster demoted to a reframed second tier. **Target-first** — the target is the primary object and agents surface inside it. **Fully derived — no new tables in Phase 2**; it depends only on the Phase 1 model existing.

- **Agent↔target bridge:** walk `agent → task.parent_id (goal) → goal.target_id → target` over the accessible task set, reusing the stuck/dormant classification in `Kanban.Agents.Roster` to produce, per target, `{derived status, member goals, active agents, stalled goals/agents}`. The derivation lives in the context (reusing `Kanban.Targets` for status), never the LiveView.
- **Delivery-health band:** a new top-of-page component bucketing targets by derived status (On-track / At-risk / Missed / Complete) with soonest target dates.
- **At-risk explainer:** for each at-risk target, its stalled member goals and the stuck/failing agents on them — turning "catch trouble early" into a named agent stall endangering a named target.
- **Reframed roster:** each agent annotated with the target/goal it advances, ordered risk-first (agents on at-risk targets float up).
- **Retained but demoted:** the activity feed, per-agent detail panel, and fleet metrics stay as a second tier, each tethered to the target/goal it serves. Agents with no goal parent still show, outside the delivery rollup.
- **Time-to-detect metric deferred:** the "time from stall to action" leading indicator needs history the derived model doesn't keep; it is a later slice, not Phase 2.

*Phase 3 (in-page interventions) design — refined during continuation on 2026-07-08.*

The `/agents` page gains its first **write actions**, moving it from observe-only to act. First cut: **Reassign (goal-level)** and **Reprioritize**.

- **Reassign is goal-level, not task-level.** It sets the goal's `assigned_to` to a new **human user** (the existing `assigned_to_id` field; the agent that user runs then claims the work) and reassigns the goal's **not-started** child tasks — those still in Backlog/Ready and unclaimed. Tasks in Doing/Review/Done keep their current assignee. An **unstarted goal** (no started children) moves wholesale.
- **Reprioritize** raises/lowers a goal's priority (and its not-started children) to steer the fleet toward an endangered target. **Load-bearing dependency:** this is only real if the claim order (`GET /api/tasks/next`) respects priority — otherwise it is theater (see Assumptions and Open questions); verifying/ensuring this is an acceptance condition for the action.
- **Who may act:** the **target owner or the board owner**, on the write path, honoring the same `BoardScope` access guard the reads use.
- **Safeguard:** a **confirmation dialog** listing exactly which tasks will move (count + list), followed by an **undo window** after it applies.
- **Concurrency:** at write time, only tasks still unclaimed are reassigned; any claimed since the confirmation dialog opened are skipped and surfaced to the lead (guards the auto-claim race).
- **Boundaries:** all writes go through `Kanban.Tasks` / `Kanban.Targets` context functions (no Ecto in the LiveView); all UI text via gettext; both light and dark mode.

## Open questions
- **Resolved (2026-07-06):** how targets/deadlines enter Stride — a dedicated workspace-level `delivery_targets` entity grouping goals; see Sketch. (The alternatives — a date on the goal row, or column-level SLAs — were rejected.)
- **Does the task-claim order (`GET /api/tasks/next`) respect goal/task priority?** This gates whether Reprioritize (seam 3) does anything real; if it doesn't, Reprioritize is theater and either the claim order must change first or the action is out of scope.
- **Is there a first-class "board owner" concept** (or clear equivalent) to back the "target owner or board owner" permission for interventions?
- Where does cost/ROI data (token/agent spend) come from to support the "leadership trust / investment paying off" metric?
- Whether APM-scale observability and/or live agent orchestration should later be pulled into scope (intentionally left open, not ruled out).

## Design challenge
*Page-level direction (2026-07-06):*
- **Blind spots:** the rejected "fold into board views" alternative may be the cure for the top adoption risk; no cost/ROI data behind the leadership-trust metric; passive dashboard vs proactive alerts tension.
- **Alternative A:** Delivery signal in the board, not a separate page — surface agent-health and delivery-risk inline on boards/goal cards, with `/agents` as a thin roll-up; meets leads where they already work.
- **Alternative B:** Push, don't pull — invest first in proactive alerts/digests (stuck agent, goal-at-risk) that link into the page, so value reaches leads without visiting a dashboard.
- **Trade-off comparison:** proposed standalone page = high cost / high adoption risk / high complexity / longest timeline; Alt A = medium cost / low adoption risk / medium complexity / medium timeline; Alt B = low–medium cost / lowest adoption risk (alert-fatigue risk) / low–medium complexity / shortest timeline. **Decision:** proceed with the proposed standalone-page direction for now; Alt A and Alt B are recorded as live options to revisit if the adoption metric lags.

*In-page interventions seam (2026-07-08):*
- **Blind spots:** Reprioritize silently depends on priority-ordered claiming (unverified); the reassign↔auto-claim concurrency race; undo semantics once an agent claims reassigned work during the undo window; whether a first-class board-owner exists; deferring **Unblock** may miss the point, since a stuck agent on an at-risk target is often *blocked* — unblock could be higher-value than reprioritize.
- **Alternative A (Unblock-first):** make clearing blockers / re-readying stuck tasks the second action instead of Reprioritize — more directly fixes the stall that makes a target at-risk. Trade-off: medium cost / medium risk / higher complexity (touches the dependency model).
- **Alternative B (Suggest, don't mutate):** the page *recommends* an intervention ("reassign G12's 3 not-started tasks?") and deep-links into the existing board/task UI to execute, rather than writing directly. Trade-off: low cost / low risk / low complexity, but a weaker "act in one place" payoff and less of the leading-metric lift.
- **Trade-off comparison:** proposed (Reassign + Reprioritize direct writes) = medium cost / **high risk (the priority-order dependency)** / medium complexity / medium timeline. **Decision (write-as-is):** proceed with Reassign + Reprioritize; keep Alt A (Unblock-first) as the leading candidate for the *next* action and Alt B (suggest-only) as the low-risk fallback if the direct-write concurrency/permission surface proves too costly.

## Concrete Example
- **User:** Dana, a delivery lead accountable for the "Q3 Launch" target.
- **Trigger:** the delivery-health band shows "Q3 Launch" as **At-risk**, and the at-risk explainer names goal *G12 "Ship the API"* with its agent flagged **stuck**.
- **Current bad path:** Dana leaves `/agents`, opens the board, finds G12, realizes the assigned agent is wedged, then messages a teammate in Slack to pick it up — the page itself did nothing but tell her something was wrong.
- **Desired good path:** from `/agents`, Dana clicks **Reassign** on G12, picks a new owner; a confirmation dialog lists the 3 not-started child tasks that will move (the 2 in-progress stay put); she confirms, an undo toast appears, and the fleet re-targets G12's remaining work — without her leaving the page.

## Decomposition seams
*A phased split so this ships as independent, dependency-ordered chunks rather than one giant goal. Each is a candidate `/stride-ideation:stridify <path> --goal <n>` dispatch. Phases 2–4 depend on Phase 1.*

1. **Target-modeling foundation** — the `delivery_targets` table + nullable `target_id` FK on goal task rows; a new `Kanban.Targets` context (CRUD, goal assignment, board-scoped listing, derived on-track status via the time-vs-progress heuristic); and the targets strip on `/boards` with drill-down to member goals. See the **Sketch** for the locked model. Prerequisite for every outcome-linked view. Ship this first. *(Shipped: goal G307.)*
2. **Delivery-outcome views** — restructure `/agents` in place from agent-centric to delivery-centric (target-first): a delivery-health band on top, an at-risk explainer tying stalled agents to endangered targets, and a risk-first reframed roster, with the existing feed/detail/metrics demoted to a second tier. **Fully derived — no migration** — via an `agent → goal → target` rollup in the context. See the **Sketch**. Depends on Phase 1. *(Shipped: goal G308.)*
3. **In-page interventions** — introduce the first **write actions** from the page, moving the surface from observe-only to act. First cut: **Reassign (goal-level)** and **Reprioritize**; Unblock and Nudge are deferred (Non-goals this iteration). **Reassign** sets a goal's `assigned_to` to a new human user and reassigns only its not-started (Backlog/Ready, unclaimed) children — Doing/Review/Done untouched; an unstarted goal moves wholesale. **Reprioritize** changes a goal's priority to steer the fleet — conditional on the claim order respecting priority (see Open questions), else it is theater. Actor: **target owner or board owner**, board-scoped. Safeguard: **confirmation dialog (lists what moves) + undo window**; the write skips any task claimed since the dialog opened (auto-claim race guard). All writes via the `Kanban.Tasks` / `Kanban.Targets` contexts, no Ecto in the LiveView. Directly serves the "interventions initiated per week" leading metric. Depends on Phase 1; complements Phase 2. See the **Sketch** (Phase 3 block) and **Design challenge** (interventions seam).
4. **ROI / cost view** — surface token/agent spend vs delivered value for the upward-reporting leader; powers the "leadership trust / investment paying off" lagging metric.
5. **Proactive alerts (deferred / conditional)** — stuck-agent and goal-at-risk notifications (Alternative B), pursued only if the adoption metric shows the pull model isn't reaching delivery leads.
