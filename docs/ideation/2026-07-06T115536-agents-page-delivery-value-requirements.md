# Enhance the /agents page to be genuinely useful to delivery organizations

*Date: 2026-07-06 11:55*
*Session: 2026-07-06T115536-agents-page-delivery-value*

## Problem
The workspace-level `/agents` page today is passive telemetry: it derives agent state (roster, activity feed, throughput, success rate) from Task records and displays it, but it drives no decision and offers no action — a delivery lead looks at it, nods, and closes the tab. Worse, the metrics it shows are disconnected from the delivery outcomes the organization is actually measured on (commitments, deadlines, delivered value). As AI-agent usage scales across the workspace, this "flying blind" becomes a growing, concrete cost — which is what makes it worth solving now rather than later.

## Goal
Transform `/agents` from a passive telemetry dashboard into a delivery-oriented control surface: connect agent activity to delivery outcomes and let the people running delivery act on what they see. The primary user is the delivery lead / engineering manager accountable for hitting commitments; the fleet operator and the upward-reporting leader are served as secondary audiences.

## Success metrics
- **leading indicators** (observable while the work is in flight, predict the outcome):
  - Delivery leads actually use it — weekly-active delivery leads and repeat visits.
  - Interventions initiated from the page (reassign, unblock, reprioritize, nudge) per week.
- **lagging indicators** (the outcome itself, observable only after it has occurred):
  - Fleet task success rate and completed-throughput per agent trend upward over time.
  - Leadership can confidently answer "is the AI investment paying off?" — measured by survey and continued/expanded investment.

## Assumptions
*Ordered highest to lowest risk; the riskiest is marked `(R)`. Each carries the challenge-gate confidence rating — `(high)` / `(medium)` / `(low)`.*
- Delivery leads want a dedicated agent surface and will fold it into their routine rather than staying in the board, standups, and Slack. (R) (low)
- Agent activity can be meaningfully tied to delivery outcomes even though Stride models tasks/boards but not sprints, deadlines, or commitments. (low)
- The interventions that actually move outcomes can be initiated from inside Stride, not only outside it. (medium)
- Serving three personas (lead / operator / leader) from one surface won't dilute the primary delivery-lead experience. (medium)
- The AI fleet is scaling enough that "flying blind" is a real, present pain worth solving now. (high)
- Existing derived data plus new persistence (permitted) is rich enough to power delivery-relevant views. (high)

## Constraints
- Deliberately unconstrained: a full redesign and new data persistence (new tables/models) are explicitly permitted if needed to achieve the objectives — the current read-only-derived architecture is *not* a boundary.
- Preserve existing per-user board access scoping (a user sees only agents/tasks on boards they can access).
- Remain within the Stride Phoenix application (no separate service).

## Non-goals
- Not tracking or managing human contributors' work — this surface is about AI agents.
- Not pivoting to a board-embedded or alert-first design in this iteration — those alternatives were considered and deferred (see Design challenge), not adopted now.

## Outcome
A delivery lead opening `/agents` (or alerted by it) can, in one place: see whether delivery is on track with agent work tied to real outcomes; catch stuck, failing, or drifting agents before they cost a deadline; and act directly — reassign, unblock, reprioritize — instead of only observing. The page has shifted from a report you glance at to a surface you manage delivery from.

## Open questions
- How do delivery commitments/deadlines enter Stride so "on track" can be computed — goal target dates, a new commitment field, or column-level SLAs? (Intentionally unresolved; this is the first thing the phased plan below pins down.)
- Where does cost/ROI data (token/agent spend) come from to support the "leadership trust / investment paying off" metric?
- Whether APM-scale observability and/or live agent orchestration should later be pulled into scope (intentionally left open, not ruled out).

## Design challenge
- **Blind spots:** the rejected "fold into board views" alternative may be the cure for the top adoption risk; no defined path for how commitments/deadlines enter Stride; no cost/ROI data behind the leadership-trust metric; passive dashboard vs proactive alerts tension.
- **Alternative A:** Delivery signal in the board, not a separate page — surface agent-health and delivery-risk inline on boards/goal cards, with `/agents` as a thin roll-up; meets leads where they already work.
- **Alternative B:** Push, don't pull — invest first in proactive alerts/digests (stuck agent, goal-at-risk) that link into the page, so value reaches leads without visiting a dashboard.
- **Trade-off comparison:** proposed standalone page = high cost / high adoption risk / high complexity / longest timeline; Alt A = medium cost / low adoption risk / medium complexity / medium timeline; Alt B = low–medium cost / lowest adoption risk (alert-fatigue risk) / low–medium complexity / shortest timeline. **Decision:** proceed with the proposed standalone-page direction for now; Alt A and Alt B are recorded as live options to revisit if the adoption metric lags.

## Decomposition seams
*A phased split so this ships as independent, dependency-ordered chunks rather than one giant goal. Each is a candidate `/stride-ideation:stridify <path> --goal <n>` dispatch. Phases 2–4 depend on Phase 1.*

1. **Commitment-modeling foundation** — decide and implement how delivery commitments/deadlines enter Stride (goal target dates vs a new commitment field vs column-level SLAs). Resolves the top Open Question and is the prerequisite for any "on track" computation. Ship this first.
2. **Delivery-outcome views** — recast `/agents` around delivery risk and on-track status tied to the Phase 1 model, anchored on the primary delivery-lead experience (redesign + new persistence land here).
3. **In-page interventions** — introduce write actions from the page (reassign, unblock, reprioritize, nudge), moving the surface from observe-only to act. Directly serves the "actions taken from page" leading metric.
4. **ROI / cost view** — surface token/agent spend vs delivered value for the upward-reporting leader; powers the "leadership trust / investment paying off" lagging metric.
5. **Proactive alerts (deferred / conditional)** — stuck-agent and goal-at-risk notifications (Alternative B), pursued only if the adoption metric shows the pull model isn't reaching delivery leads.
