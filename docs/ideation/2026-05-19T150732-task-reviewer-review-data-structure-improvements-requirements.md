# Extend G142: end-to-end structured task-reviewer review-report contract

*Date: 2026-05-19 15:07*
*Session: 2026-05-19T150732-task-reviewer-review-data-structure-improvements*

## Problem

The task-reviewer subagent emits free-form prose: a summary line, a markdown-formatted issues list grouped by severity, an acceptance-criteria table, and prose sections for testing strategy, patterns followed, and pitfalls. The Stride server stores this as two parallel fields on the task: `review_report` (a markdown string) and `reviewer_result` (a JSON blob carrying only `summary`, `dispatched`, `duration_ms`, `issues_found`, `acceptance_criteria_checked`).

Today's Kanban app `/review` queue extracts everything visual — the acceptance grid, the testing-strategy cell, the patterns-followed cell, the pitfalls cell — by **regex-parsing the markdown `review_report` field** in `lib/kanban_web/live/review_live.ex`. The Task Show and Task Edit views surface even less. The current `reviewer_result` schema carries integer counts but no per-issue location, severity breakdown, or per-criterion verdict.

Existing Goal G142 in Stride addresses only the plugin-side half of the contract: define a fenced JSON schema in `stride/agents/task-reviewer.md`, parse it in `stride/skills/stride-workflow/SKILL.md`, release `stride` v1.13.0, bump `stride-marketplace`. G142 does not touch the kanban app (no schema migration, no validator change, no UI rewrite), does not address the five other plugin variants (`stride-copilot`, `stride-codex`, `stride-gemini`, `stride-opencode`, `stride-pi`) that emit the same review payload, and does not cover `testing_strategy`, `patterns`, or `pitfalls` as first-class fields even though those are the sections the Kanban regex parser currently extracts.

## Goal

Deliver an end-to-end structured task-reviewer review-report contract: a documented JSON schema emitted by every Stride client plugin variant (six total), extracted by the workflow skill in each variant, validated and stored by the Stride Kanban app, and rendered by a reused review-panel component across the `/review` queue, Task Show, and Task Edit screens. Retire markdown regex-parsing as the production rendering path for newly completed tasks; keep it as a permanent legacy fallback for tasks completed before the rollout.

## Success metrics

- **leading indicators** (observable while the work is in flight, predict the outcome):
  - For every newly completed task after the rollout, the `/review` screen renders without invoking the markdown regex fallback path. Measured via a `review.fallback_used` telemetry counter that stays at 0 for new tasks, and a `review.structured_used` counter that rises in lockstep with completion volume.
  - All six plugin variants (`stride`, `stride-copilot`, `stride-codex`, `stride-gemini`, `stride-opencode`, `stride-pi`) reflect the structured-emission contract in their marketplace JSON within 14 days of starting the rollout. Measured by inspecting the `version` field of each plugin entry in its respective `marketplace.json` and confirming the corresponding git tag exists on origin.

- **lagging indicators** (the outcome itself, observable only after it has occurred):
  - When the schema is extended later with a new field (e.g., a `security_concerns` array, or a per-issue `confidence` score), the Kanban app **accepts and persists** the new field with **no Kanban deploy required**. Scope of this metric is **storage only**, not rendering: `reviewer_result` is `:jsonb` so the column accepts arbitrary nesting; the validator tolerates unknown forward-compatible fields; the UI ignores fields it does not recognize. Adding *display* of a new field still requires a UI deploy and is explicitly out of scope of this metric. Observable the next time a field is added: if the addition required a Kanban deploy *just to accept and persist*, this metric failed.

## Assumptions

*Ordered highest to lowest risk; the riskiest entry is marked `(R)`.*

- **(R)** All six plugin agents — running across different model providers (Claude in `stride` / `stride-codex`, Copilot, Gemini, Pi/Kimi K2, OpenCode) — will reliably emit a single well-formed fenced ```json block matching the documented schema on every dispatch, including Approved runs and edge cases (no acceptance criteria in the task, no issues to report). *Premortem-derived: the most likely failure mode is divergent structured-output behavior across model providers, with no server-side repair layer, leaving the markdown fallback path firing for 10–20% of new tasks instead of 0%.*
- The schema's five top-level finding fields (`issues`, `acceptance_criteria`, `testing_strategy`, `patterns`, `pitfalls`) cover everything reviewers currently flag in prose. New concerns (security, performance, accessibility) that reviewers want to highlight will fit either inside the existing `category` enum on `issues[]` or by adding sibling fields that `schema_version` gates.
- A single reused panel component (rendering status, summary, severity-grouped issue list, acceptance grid, and the three section verdicts) is appropriate for `/review`, Task Show, and Task Edit — no view-specific divergence is needed beyond density and editability.
- Coordinating six plugin-repo releases and six marketplace-repo bumps inside a 14-day window is operationally feasible. Each plugin variant has the same release procedure documented; the work is mechanical once the schema is locked.
- Tasks completed before the rollout — which have only `review_report` markdown populated — will keep rendering acceptably via the legacy regex fallback path indefinitely. No backfill is performed; the fallback path is the permanent home of pre-rollout history.
- The agent's underlying five-step review methodology (Acceptance Criteria Verification, Pitfall Detection, Pattern Compliance, Testing Strategy Alignment, General Code Quality) stays intact. Only the *output format* changes; the *review work* does not.

## Constraints

- **Backwards compatible**: clients running an older plugin version after the rollout MUST continue to function. The Kanban API validator MUST accept the current `reviewer_result` shape (`summary` + integer counts only) without rejecting it, and the UI MUST detect-and-degrade when the structured fields are absent — falling through to the markdown regex fallback path.
- **Lockstep release across all six plugin variants**: `stride`, `stride-copilot`, `stride-codex`, `stride-gemini`, `stride-opencode`, `stride-pi`. Each variant's `task-reviewer` prompt and `stride-workflow` / `completing-tasks` skill must be updated together; each variant's marketplace entry must be bumped together. Splitting the release across variants leaves the fleet permanently fragmented.
- **No changes to the agent's review methodology**: the five-step review process is out of scope. Only the emission format and downstream consumption change.
- **No changes to the existing `review_report` markdown emission**: agents continue to emit human-readable prose above the JSON block, both because the markdown is the legacy fallback for old kanban clients and because reviewers reading the agent's raw output benefit from the prose.
- **Schema MUST carry an explicit `schema_version` field** (semver string, starting at `"1.0"`) so future field additions don't require coordinated kanban-app code deploys.

## Non-goals

- **Telemetry / metrics rollups on review data**: per-severity historical trends, reviewer time-spent dashboards, per-category aggregates. The structured schema enables these but building them is a separate goal.
- **Reworking the agent's underlying review methodology**: the five-step review process is preserved verbatim.
- **Board view changes**: board cards do not gain severity badges, filter chips, or any other review-derived rendering in this iteration.
- **Notifications based on severity**: no email / push / in-app notifications triggered by critical findings.
- **Self-reported review path (`skip_form`)**: when a workflow takes the no-subagent path, `reviewer_result` continues to carry only the existing summary + skip-reason; it does not gain structured `issues[]` or `acceptance_criteria[]` fields. The new review panel renders skip_form tasks via the existing summary-and-skip-reason layout (no structured grid, no issue list) — independent of the structured rendering path described in the Outcome.
- **A migration backfilling structured data into old tasks**: pre-rollout tasks stay in the markdown fallback path.

## Outcome

After this ships, the lifecycle of a task review is:

1. The agent (any of six plugin variants) finishes its review methodology, then emits a single fenced ```json block containing: `schema_version`, `summary`, `status`, `issue_counts`, `issues[]`, `acceptance_criteria[]`, `testing_strategy`, `patterns`, `pitfalls`. The human-readable prose summary continues to appear above the JSON block.
2. The workflow skill (in any of six plugin variants) extracts the JSON block, parses it, and PATCHes `/api/tasks/:id/complete` with `reviewer_result` carrying the full payload — and still PATCHes `review_report` with the markdown narrative.
3. The Kanban app's `Kanban.Tasks.CompletionValidation` accepts the richer payload, validating shape and enum values for known fields and tolerating unknown forward-compatible fields. The task record persists `reviewer_result` jsonb with the full structure intact.
4. The `/review` queue, Task Show, and Task Edit screens render a reused panel that displays status, summary, severity-grouped issue list (with file:line, category, description, suggested fix), per-criterion acceptance grid, and the three section verdicts (testing strategy / patterns / pitfalls). The markdown regex parsing in `lib/kanban_web/live/review_live.ex` is no longer the production code path for newly completed tasks — it lives on as the dormant legacy path that fires only when `reviewer_result.issues` is absent.
5. Old tasks (completed before the rollout) continue to render via the markdown legacy path. New tasks completed via the subagent path always render via the structured path. Skip_form tasks (those completed via the no-subagent path) continue to render via the existing summary-and-skip-reason layout — they neither gain structured fields nor lose anything.

The end-state surfaces the same human-readable information reviewers see today — but driven by structured fields rather than regex extraction, opening the door for telemetry, filtering, and richer rendering in future iterations.

## Sketch

The work decomposes naturally along producer / contract / consumer lines. The reviewer flagged that the full scope spans three orthogonal feature areas — producer changes (12 atomic plugin edits across 6 repos), contract changes (server-side schema + validator + docs), and consumer changes (a new shared LiveComponent wired into 3 UI surfaces) — and recommended splitting into separate goals before decomposition. The seams below are written with that in mind: the decomposer can choose to treat them as one goal with three sub-trees, or split into three sibling goals with explicit dependencies.

**Producer changes (six plugin variants × two file changes each = 12 atomic edits):**
- Update each variant's task-reviewer agent prompt (`agents/task-reviewer.md` or equivalent) to emit the expanded schema (`testing_strategy`, `patterns`, `pitfalls` as first-class fields, plus `schema_version`).
- Update each variant's `stride-workflow` / `completing-tasks` skill to extract the expanded fields into the PATCH payload.
- For each variant: bump `CHANGELOG.md`, tag, push, bump marketplace entry, push marketplace tag.
- G142's existing W684 / W685 / W686 / W687 cover this for the `stride` variant only; the other five variants need parallel work tasks.

**Contract changes (Stride server-side):**
- `Kanban.Tasks.CompletionValidation`: extend `validate_reviewer_result/1` to accept the new optional fields (issues array, acceptance_criteria array, testing_strategy, patterns, pitfalls, schema_version) and validate their shape and enum values. Unknown fields are tolerated.
- Migration: `reviewer_result` is already `:jsonb` — no DB schema change needed. The validator change is what unlocks the richer payloads.
- API JSON output: ensure `Kanban.Tasks.Task` serialization passes through the new fields verbatim.
- Documentation: update `agent_json.ex` `reviewer_result_format` description, the completion-validation guidance referenced from CLAUDE.md, and the canonical schema reference in the docs site.

**Consumer changes (Kanban app UI):**
- Build a reusable `KanbanWeb.ReviewReportPanel` LiveComponent that takes a task and renders the structured-or-fallback view internally. The detection rule: `if reviewer_result["issues"] is a list → render structured; elsif review_report is non-empty → render markdown via existing regex path; else → render nothing`.
- Wire the panel into `/review` (replacing the current ad-hoc rendering in `KanbanWeb.ReviewLive` + helpers in `review_live.ex`), Task Show, and Task Edit.
- Retain `lib/kanban_web/live/review_live.ex` markdown-parsing helpers (`testing_strategy_value`, `patterns_value`, `pitfalls_value`, `report_section`, etc.) as the legacy code path. Add a `review.fallback_used` telemetry counter that fires once per render path.
- Update `KanbanWeb.ReviewStatsStrip` to source its cells from the structured fields when available.

**Cross-cutting:**
- Define the schema once in a docs file in the `stride` repo and reference it from each variant plugin's `task-reviewer.md` to keep them in lockstep.
- Schema versioning: every emitter writes `"schema_version": "1.0"` initially; the Kanban validator does not require it but accepts it when present, and future minor bumps add optional fields without breaking validation.

## Open questions

- **Goal decomposition shape**: should this be a single goal with three sub-trees (producer / contract / consumer), three sibling goals with explicit dependencies (contract → consumer; contract → producer-per-variant), or kept as an extension to G142? The reviewer flagged the total scope as likely too large for a single decomposable initiative. Decide at decomposition time.
- **Schema location of record**: should the canonical JSON Schema live in the `stride` plugin repo (referenced by the others), in the Kanban app repo, or in a third shared repo? The decomposer should pick this before the producer-side tasks land.
- **Server-side repair / coercion for malformed JSON**: do we want a defensive parser layer in the Stride server that attempts to recover obvious mistakes (snake_case ↔ camelCase, missing closing brace, multiple JSON blocks) before falling back to markdown rendering? Or is "strict parse, fall through to markdown" sufficient? Premortem suggests the former lowers the riskiest assumption's blast radius.
- **Acceptance-grid status enum**: G142's parent schema uses `met` / `not_met` strings for per-criterion status. The kanban app's `@status_line_regex` currently uses `met` / `not met`. Pick the canonical form before the schema is locked.
- **`schema_version` enforcement on the server**: should the validator emit a structured warning when `schema_version` is absent (forward-compat signal for clients to upgrade), or stay silent?
- **Plugin-variant release sequencing inside the 14-day window**: pick an order (`stride` first because the schema doc lives there, then variants alphabetical?) and document it in the decomposed tasks.
