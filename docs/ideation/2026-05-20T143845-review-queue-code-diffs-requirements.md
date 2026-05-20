# Review Queue Code Diffs

*Date: 2026-05-20 14:38*
*Session: 2026-05-20T143845-review-queue-code-diffs*

## Problem

When reviewing a completed task, reviewers cannot see the code that changed without leaving Stride. Some reviewers context-switch to git or GitHub to find the diff (slow, breaks flow); others review blind from the agent's prose report alone (risk of missing regressions). The changed-files list is already on the review queue page, but clicking a file does nothing — there is no inline mechanism to see what actually changed.

## Goal

Reviewers can approve or reject the **common reviewable change** without leaving Stride. Outlier cases (very large refactors, binary-heavy changes, files exceeding the truncation cap) retain a documented escape hatch to the full diff in the repo. Full-fidelity parity with GitHub's diff view is explicitly **not** the target — the goal is "sufficient for the common case," not "complete replacement."

## Success metrics

- **Leading indicators** (observable while the work is in flight, predict the outcome):
  - Diff panel open-rate AND time-spent-in-panel on tasks where `needs_review = true`. Open-rate alone catches engagement; time-spent catches the failure mode where reviewers open the panel, immediately bounce, and finish the review elsewhere. Watched continuously after first deploy.
- **Lagging indicators** (the outcome itself, observable only after it has occurred):
  - Reviewer self-report: > 80% of surveyed reviewers say "I review without leaving Stride" within 8 weeks of GA.

## Assumptions

*Ordered highest to lowest risk; the riskiest entry is marked `(R)`. Each entry is phrased as a failure mode the design depends on NOT happening.*

- **(R)** Reviewers do not need search, cross-file navigation, blame, or history to approve the common reviewable change. If they do, they will open the diff panel once, bounce back to GitHub or their IDE, and continue reviewing from outside Stride — making the panel a vanity surface and the open-rate metric a false positive.
- The cases where a per-file diff exceeds the 500-line cap are rare enough — and the "view full in repo" escape hatch trustworthy enough — that the panel does not become known as "useless for the reviews that actually matter." If high-stakes refactors are the cases that trip the cap, reviewers will learn to skip the panel even on smaller reviews.
- Plugins do not silently fail to capture diffs on a non-trivial fraction of tasks. A panel that is empty more than occasionally erodes trust faster than a missing panel ever would; reviewers will stop checking it.
- The added per-file diff payload does not inflate the task record enough to slow the review queue page or the task list — i.e., the feature does not degrade performance of the very view it is meant to improve.
- Reviewers actually open the diff panel often enough that engagement metrics carry signal. If open-rate is floor-bound to zero, the leading metrics are uninformative and we have no early-warning signal for the lagging self-report.

## Constraints

- Must not break the existing review queue flow — reviewers who do not engage with diffs see no degradation; the current report layout stays intact.
- Plugin change must be backward-compatible — older agent versions that don't send diff data still produce a working review (no diff panel, but no crash or empty state that blocks reviewers).
- Diff rendering must work in both light and dark mode (per repo `CLAUDE.md` — UI changes are verified in both modes before completion).
- Prefer minimal dependencies — render with existing tools or a small library; avoid heavy diff-viewer dependencies.

## Non-goals

- Inline comments / line-by-line review threads — reviewers see the diff but cannot comment on specific lines. The existing review-notes mechanism remains the channel for feedback. *Reason: scope discipline; comment infrastructure is a separate initiative.*
- Editing or proposing changes from the diff panel — read-only display, no PR-style suggestions. *Reason: out of scope for "see the changes"; suggesting changes is a separate workflow.*
- Diff rendering for binary files (images, compiled artifacts) — binary file changes are listed with a "binary file changed" placeholder; no preview attempted. *Reason: binary rendering is a deep rabbit hole and not on the critical path.*
- Split / side-by-side diff view — unified-diff only in v1. *Reason: keep the v1 surface small; side-by-side can follow if reviewers ask.*

## Outcome

A reviewer opens a task in the review queue, reads the agent's report, and sees the changed-files list as before. Clicking any file in that list opens an inline diff panel rendered next to the report, showing the unified diff for that file. The diff is populated from per-file entries already present in the structured review JSON (captured by the agent's plugin during completion). Files larger than the 500-line cap show a truncated view with a notice and a link to view the full diff in the repo. The reviewer reads, decides, and approves or rejects — all without leaving the Stride review queue page for the common case.

## Sketch

- **Plugin change**: agent plugins gain a step (during or just before the review submission) that runs `git diff` per changed file relative to the task's base, truncates to 500 lines per file with a notice marker, and writes the unified-patch text into the existing per-file entry in the structured review JSON. Backward-compatible: omitted on older plugin versions.
- **Server-side**: review JSON schema gains an optional `diff` field per changed-file entry. Storage and read paths handle missing-or-present transparently.
- **UI**: review queue page (`lib/kanban_web/live/review_live.ex` and the changed-files component) gains a clickable affordance on each file in the existing list. Clicking opens an inline panel rendering the unified diff with syntax-aware coloring (additions / removals) and a truncation notice when applicable.
- **Instrumentation**: telemetry events when the diff panel opens and when it closes, scoped to `needs_review = true` tasks. Both events used to compute open-rate and time-spent leading metrics.

## Decomposition seams

**This document MUST be decomposed into seven independent goals — one per surface.** The decomposer should NOT collapse the plugin work into a single goal; each plugin lives in its own repo, ships on its own cadence, and has its own maintainer surface.

The seven surfaces:

1. **Kanban app** (this repo: `lib/kanban_web/...`, `lib/kanban/...`, `priv/repo/migrations/...`) — defines the per-file `diff` field in the structured review JSON schema, persists it, and renders the inline diff panel in the review queue page. Also owns the open-rate and time-spent telemetry. **This goal MUST land (or at minimum publish a committable spec for) the JSON contract before any plugin goal can verify its capture end-to-end.**
2. **stride plugin** (this repo: `stride/`) — reference workflow plugin. Adds per-file `git diff` capture during the completion / review-submission step, applies the 500-line per-file truncation with a notice marker, writes the unified patch into the existing per-file entry in the structured review JSON.
3. **stride-copilot** (separate repo) — same diff-capture contract, adapted to Copilot CLI's tool surface.
4. **stride-gemini** (separate repo) — same contract, adapted to Gemini CLI.
5. **stride-codex** (separate repo) — same contract, adapted to Codex.
6. **stride-opencode** (separate repo) — same contract, adapted to OpenCode.
7. **stride-pi** (separate repo) — same contract, adapted to Pi Coding Agent.

**Shared contract.** All six plugins write against a single per-file diff JSON shape (field name, truncation marker convention, encoding rules). The kanban-app goal owns the contract definition; the six plugin goals each *consume* it. The contract belongs in a single short reference doc (or a section of the kanban-app goal) so a change to it is visible to every plugin maintainer.

**Sequencing & dependencies.**

- The kanban-app goal goes first (or at minimum publishes the JSON contract before any plugin goal closes).
- The six plugin goals can ship in any order and in parallel — they have no cross-dependencies on each other.
- Backward compatibility (constraint above) means an older plugin that hasn't shipped diff capture yet still produces a working review; the diff panel simply renders empty / unavailable for those tasks. No coordinated cutover is required.

## Open questions

- Diff styling library: roll-our-own minimal CSS for `+` / `-` lines vs. a small library like `diff2html`. Decide during implementation based on dependency cost and dark-mode support.
- Where exactly the plugin captures the diff (during `after_doing`, or as a dedicated review-prep step) — depends on what's already available in the plugin lifecycle when the review JSON is assembled.
- How to handle very large numbers of changed files (e.g., 50+) — out of scope for v1 framing but worth noting as a future refinement.
