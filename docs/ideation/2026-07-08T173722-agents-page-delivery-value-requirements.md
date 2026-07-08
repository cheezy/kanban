# Enhance the /agents page to be genuinely useful to delivery organizations

*Date: 2026-07-08 17:37*
*Session: 2026-07-08T173722-agents-page-delivery-value*

## Problem
The workspace-level `/agents` page today is passive telemetry: it derives agent state (roster, activity feed, throughput, success rate) from Task records and displays it, but it drives no decision and offers no action — a delivery lead looks at it, nods, and closes the tab. Worse, the metrics it shows are disconnected from the delivery outcomes the organization is actually measured on (targets, deadlines, delivered value). As AI-agent usage scales across the workspace, this "flying blind" becomes a growing, concrete cost — which is what makes it worth solving now rather than later.

**Seam #4 (this continuation) closes the one gap the shipped seams do not touch: cost and value-for-money.** Seams 1–3 connect agent activity to delivery outcomes and let leads act, but Stride still records *zero* agent cost — no tokens, no dollars, no spend, only an agent model-name string. Leadership therefore cannot answer the question it is actually asked in budget reviews — *"is the AI investment paying off?"* — and, now that the fleet has scaled enough that unaccounted spend is a material line item, that blind spot has crossed from theoretical to a present cost.

## Goal
Transform `/agents` from a passive telemetry dashboard into a delivery-oriented control surface: connect agent activity to delivery outcomes and let the people running delivery act on what they see. The primary user is the delivery lead / engineering manager accountable for hitting targets; the fleet operator and the upward-reporting leader are served as secondary audiences.

**Seam #4 goal:** give the organization a **tiered ROI surface** that finally sets agent spend against delivered value — a leader-facing fleet ROI *trend* (the funding narrative) plus a lead-facing per-agent / per-target value-per-cost drill-down — so that "is the AI investment paying off?" has a real, defensible home rather than a manually assembled slide.

## Success metrics
- **leading indicators** (observable while the work is in flight, predict the outcome):
  - Delivery leads actually use it — weekly-active delivery leads and repeat visits.
  - Interventions initiated from the page (reassign, reprioritize) per week.
  - *(Seam 4)* The **leader persona opens the ROI view regularly** — weekly-active leaders, with opens clustered around budget/review moments. If nobody opens it, the funding narrative never happens.
  - *(Seam 4)* **Cost-coverage of completed work** — % of agent-completed tasks that carry a cost figure (estimated in v1, real later). Low coverage means the ROI number is thin before anyone acts on it.
- **lagging indicators** (the outcome itself, observable only after it has occurred):
  - Fleet task success rate and completed-throughput per agent trend upward over time.
  - Leadership can confidently answer "is the AI investment paying off?" — measured by survey and continued/expanded investment. *(Seam 4 is the surface where this metric finally lands.)*
  - *(Seam 4)* **Fleet value-per-cost trends upward** over time as the org acts on the outliers the ROI drill-down surfaces (retune / reassign / cut low-value-per-dollar agents).

## Assumptions
*Ordered highest to lowest risk; the riskiest is marked `(R)`. Each carries the challenge-gate confidence rating — `(high)` / `(medium)` / `(low)`.*
- **(Seam 4, premortem-derived)** Leaders will trust a clearly-*labeled* **estimated** dollar figure enough to act on the ROI *trend*, rather than dismissing the entire view because it isn't their exact provider bill. If wrong, the estimate-now hybrid produces a number nobody believes and the whole surface is discounted. (R) (low)
- Delivery leads / leadership will fold these agent surfaces into their routine rather than staying in the board, standups, and Slack. (This is both the parent adoption risk and seam 4's "leader actually opens it".) (low)
- **(Seam 4)** At least *some* agent runtimes will eventually report real token/cost at `/complete`, so the "capture-later" half of the hybrid materializes and accuracy improves post-ship. If none ever do, the view is estimate-only forever. (low)
- Agent activity can be meaningfully tied to delivery outcomes even though Stride models tasks/boards but not sprints, deadlines, or targets. (low)
- **(Seam 4)** The pricing-table × usage-proxy estimate is *directionally* accurate — the trend it shows tracks real spend even when absolute numbers are off. (medium)
- **(Seam 4)** Complexity-weighted completed tasks are a meaningful value proxy, and self-assigned complexity is not gamed or noisy enough to make value-per-cost rankings misleading. (medium)
- The interventions that actually move outcomes can be initiated from inside Stride, not only outside it. (medium)
- "Target owner or board owner" is the right actor set for who may intervene — it matches who actually runs delivery, and a first-class board-owner concept exists (or a clear equivalent). (medium)
- Serving three personas (lead / operator / leader) from one surface won't dilute the primary delivery-lead experience. (medium)
- **(Seam 4)** A per-model **pricing table** can be kept current as models and prices change. (high)
- Existing derived data (model-name string, `time_spent_minutes`, `complexity`/`actual_complexity`, `delivery_targets`, completion/approval) plus new persistence (permitted) is rich enough to power a directional ROI view and the delivery-relevant views. (high)
- The AI fleet is scaling enough that unaccounted spend / "flying blind" is a real, present pain worth solving now. (high)

## Constraints
- Deliberately unconstrained: a full redesign and new data persistence (new tables/models/columns) are explicitly permitted if needed to achieve the objectives — the current read-only-derived architecture is *not* a boundary.
- Preserve existing per-user board access scoping (a user sees only agents/tasks on boards they can access) on both the read and the write path.
- Remain within the Stride Phoenix application (no separate service).
- In-page write actions and all ROI reads/writes run through the existing context modules (`Kanban.Tasks` / `Kanban.Targets`, or a new cost/ROI context), never Ecto in the LiveView, and honor board access scoping on the write path exactly as reads do.
- **(Seam 4)** Every estimated dollar figure MUST be visibly labeled **"estimated"**, with its method (pricing table × usage proxy) disclosable in the UI, and MUST NOT be presented as billing-grade — until real reported cost backs a given task, at which point that task's figure may drop the label. This is the load-bearing guard against false precision to leadership.
- All UI text via gettext; every new surface verified in both light and dark mode.

## Non-goals
- Not tracking or managing human contributors' work — this surface is about AI agents.
- Not pivoting to a board-embedded or alert-first design in this iteration — those alternatives were considered and deferred (see Design challenge), not adopted now.
- In-page interventions (seam 3) ship as **Reassign + Reprioritize only**; **Unblock** and **Nudge** are explicitly deferred (recorded as live options to revisit), not built now.
- Not reassigning in-progress or completed work — Reassign touches only a goal and its not-started (Backlog/Ready, unclaimed) children.
- **(Seam 4, v1) The ROI / cost view does NOT include:**
  - **Budget enforcement / spend caps** — no auto-capping, throttling, or killing agents over budget. Seam 4 reports ROI; it does not control spend. (Enforcement is a possible far-future seam.)
  - **Real-time / per-call cost metering** — costs are aggregated per completed task and rolled up on the leader's periodic-review cadence, not streamed live.
  - **Billing-grade / invoice-reconciled precision** — the estimated figure is a labeled trend indicator, never reconciled against a provider bill in v1.
  - **Human-vs-agent cost comparison** — no "agents are cheaper than humans" framing or labor-cost modeling; the view compares agent spend to delivered value only.

## Outcome
A delivery lead opening `/agents` (or alerted by it) can, in one place: see whether delivery is on track with agent work tied to real outcomes; catch stuck, failing, or drifting agents before they cost a deadline; and act directly — reassign a goal's not-started work to a different owner, or reprioritize it — instead of only observing. The page has shifted from a report you glance at to a surface you manage delivery from.

**With seam #4, leadership gains its own altitude on that same surface:** an upward-reporting leader can open the ROI view and see, as an explicitly-*estimated* dollar trend, whether the fleet's spend is producing proportionate delivered value — and a delivery lead can drill into per-agent / per-target value-per-cost to find where spend outruns value. The organization can now answer "is the AI investment paying off?" from live data instead of a hand-built spreadsheet, and that answer gets more accurate over time as agents begin reporting real cost — with no rebuild.

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

*Phase 4 (ROI / cost view) design — scoped during continuation on 2026-07-08.*

The workspace gains a **tiered ROI surface** (on `/agents` or a dedicated ROI view) that sets agent **spend** against **delivered value**. The cost model is **estimate-now, capture-later** — it produces a dollar trend on day one and grows more accurate over time without a rebuild.

- **Cost model (hybrid):** v1 derives an **estimated** per-task cost = `pricing_table[model_name] × usage_proxy(time_spent_minutes, complexity)`, computed at read time (or stamped on completion) and **retroactive** over existing tasks. New **nullable** real-cost columns (`input_tokens`, `output_tokens`, `cost_usd`) — or a `metrics_events` metric — are added from the start; when an agent reports real cost at `/complete`, it **overrides** the estimate for that task. Every figure renders as **"estimated"** with the method disclosable until real data backs it.
- **Value unit:** delivered value = Σ completed (approved) tasks weighted by complexity (small / medium / large → tunable points, e.g. 1 / 3 / 8), attributed to an agent and, where the goal is target-linked, to a delivery target. **Weighting field:** prefer `actual_complexity` (the post-hoc, measured value) when it is set, falling back to the self-assigned `complexity` when it is absent — the measured field is harder to game, which directly mitigates the per-agent value-per-cost perverse-incentive risk (see Design challenge).
- **Tier 1 — leader (funding narrative):** a fleet-level ROI *trend* over time (estimated spend vs delivered value). The home for the parent's "is the investment paying off?" lagging metric. Optimized for a periodic, defensible narrative, **not** real-time control.
- **Tier 2 — lead (efficiency drill-down):** per-agent and per-target **value-per-cost**, surfacing outliers where spend outruns value, to retune / reassign / cut — complementing seam 3's interventions.
- **Data source:** primarily existing derived data (model-name string, `time_spent_minutes`, `complexity`/`actual_complexity`, `delivery_targets`, completion/approval) plus the new nullable cost columns; a config-owned per-model **pricing table** supplies rates.
- **Boundaries:** reads/writes via context modules (no Ecto in the LiveView); board-scoped exactly as existing reads; gettext; light + dark.
- **Pricing-table & proxy caveats (from the challenge gate):** unmapped or `?` model names must fail **visibly** (surfaced as "unpriced"), never silently cost $0; the `time_spent_minutes` proxy is nullable and self-reported, so a fallback (e.g. complexity-only) is required when it is absent.
- **Illustrative walkthrough:** a leader opens the ROI view before a quarterly budget review and sees fleet delivered-value climbing while *estimated* spend flattens — a defensible "paying off" trend, clearly labeled estimated. Drilling into tier 2, the delivery lead spots one agent whose value-per-cost sits well below the fleet, flagged for retuning — an insight that previously required exporting task data to a spreadsheet.

## Open questions
- **Resolved (2026-07-06):** how targets/deadlines enter Stride — a dedicated workspace-level `delivery_targets` entity grouping goals; see Sketch. (The alternatives — a date on the goal row, or column-level SLAs — were rejected.)
- **Resolved (2026-07-08):** where cost/ROI data comes from — an **estimate-now, capture-later hybrid**. v1 estimates cost from the model-name string × a pricing table × a usage proxy (`time_spent_minutes` / `complexity`), retroactive over back-data; nullable real-cost columns override per task as agents begin reporting real token/cost at `/complete`. (The alternatives — real-capture-first, and value-only-no-dollars — were rejected/deferred; see Design challenge.)
- **Does the task-claim order (`GET /api/tasks/next`) respect goal/task priority?** This gates whether Reprioritize (seam 3) does anything real; if it doesn't, Reprioritize is theater and either the claim order must change first or the action is out of scope.
- **Is there a first-class "board owner" concept** (or clear equivalent) to back the "target owner or board owner" permission for interventions?
- **(Seam 4) How is failed / rejected-work cost treated?** Agents burn real spend on tasks that fail or get rejected, and that spend has *zero* value numerator. Options: count it in the denominator (honest ROI), surface it separately as "wasted spend", or explicitly defer it. Recorded as a live blind spot; see Design challenge.
- **(Seam 4) How is delivered value attributed across a goal touched by multiple agents** for a per-agent value-per-cost ranking? Undefined in v1.
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

*ROI / cost view seam (2026-07-08):*
- **Blind spots:** **failed/rejected-work cost** has real spend but zero value (ROI overstated if ignored); the usage proxy leans on the nullable, self-reported `time_spent_minutes` field; the model-name → pricing-row mapping is fragile (unknown / `?` models could silently cost $0); per-agent **value attribution on shared goals** is undefined; a public **value-per-cost-per-agent ranking risks perverse incentives** (gaming complexity, dodging large tasks).
- **Alternative A (value-only until real cost):** ship the value side with *no dollars at all* in v1; add cost strictly when real reported cost exists. Sidesteps the `(R)` estimate-trust risk entirely. Trade-off: low cost / low risk / low complexity / short timeline — but no leadership $ narrative in v1.
- **Alternative B (provider-bill import):** periodically import the actual provider invoice and allocate it across agents/tasks by the usage proxy. Real dollars without per-runtime cooperation. Trade-off: med-high cost / medium risk / higher complexity (import + allocation) / longer timeline.
- **Trade-off comparison:** proposed (tiered estimate-now / capture-later hybrid) = medium cost / **high risk (estimate-trust)** / medium complexity / medium timeline. **Decision (write-as-is):** proceed with the tiered estimate-now/capture-later hybrid; keep **Alt B (provider-bill import)** as the recorded live path to *real* dollars, and **Alt A (value-only)** as the low-risk fallback if the estimate proves untrusted.

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
4. **ROI / cost view** — a **tiered** surface setting agent **spend** against **delivered value**, giving leadership the "is the AI investment paying off?" answer from live data. **Tier 1 (leader):** a fleet ROI *trend* (estimated spend vs delivered value) — the home for the parent's investment-paying-off lagging metric. **Tier 2 (lead):** per-agent / per-target **value-per-cost** with outliers, complementing seam 3. **Cost model = estimate-now, capture-later hybrid:** v1 estimates cost = `pricing_table[model_name] × usage_proxy(time_spent_minutes, complexity)` (retroactive over back-data); nullable real-cost columns (`input_tokens` / `output_tokens` / `cost_usd`) override per task as agents report real cost at `/complete`; every figure labeled **"estimated"** until real-backed. **Value unit:** complexity-weighted completed (approved) tasks (prefer measured `actual_complexity`, fall back to self-assigned `complexity`), target-attributed. **v1 non-goals:** budget enforcement/caps · real-time per-call cost · billing-grade precision · human-vs-agent comparison. Reads/writes via context modules, board-scoped, gettext, light+dark. Depends on Phase 1 (targets) for target-attribution; independent of seam 3. See the **Sketch** (Phase 4 block), **Assumptions** (the `(R)` estimate-trust bet), and **Design challenge** (ROI seam). Powers the "leadership trust / investment paying off" lagging metric.
5. **Proactive alerts (deferred / conditional)** — stuck-agent and goal-at-risk notifications (Alternative B), pursued only if the adoption metric shows the pull model isn't reaching delivery leads.
