# Add after_goal hook for Stride

*Date: 2026-05-14 11:04*
*Session: 2026-05-14T110423-after-goal-hook*

## Problem

Stride currently supports four developer-defined hooks — `before_doing`, `after_doing`, `before_review`, `after_review` — all scoped to a single task's lifecycle. There is no hook that fires at goal completion. Work that should run exactly once when a goal is fully done (the canonical example: opening a consolidated pull request that bundles every child task's commits) either has to run N times across N child tasks or doesn't have a consistent home in `.stride.md` at all. Today a multi-task goal can produce N PRs, N deploy notifications, N integration runs — and there's no protocol-level place to say "this is the one thing that runs when the goal as a whole is finished."

## Goal

Ship a fifth developer-defined hook, `after_goal`, that fires once per goal completion, follows the existing hook protocol (server returns hook metadata in an API response, agent executes locally from `.stride.md`, agent reports result back), and gates the goal's transition to Done on the hook's success. The hook is general-purpose — PR creation is the canonical use case, but the hook itself is not coupled to it.

## Success metrics

- **leading indicators** (observable while the work is in flight, predict the outcome):
  - **Protocol plumbing works:** server returns `after_goal` hook metadata in the completion / mark_reviewed response of the final child task. Verified by an end-to-end integration test plus a production telemetry counter on the completion endpoint.
  - **Adoption is happening:** percentage of active projects whose `.stride.md` declares a non-empty `## after_goal` section trends upward week over week after launch. This metric speaks directly to the riskiest assumption: if adoption stalls near zero, the lagging latency metric will have too few samples to be meaningful and the feature will quietly underperform.
- **lagging indicators** (the outcome itself, observable only after it has occurred):
  - **Goal-to-Done latency stays bounded** on goals that exercise after_goal: tight p95 (e.g., < 5 minutes for the PR-creation use case) measured from the final after_review completion to the goal-Done transition. Goals with no `## after_goal` declaration are excluded from this metric.

## Assumptions

*Ordered highest to lowest risk; the riskiest entry is marked `(R)`.*

- **(R) Users will actually add `## after_goal` sections to their `.stride.md` and configure them to do meaningful goal-level work.** The back-compat path treats a missing `## after_goal` as an empty no-op hook, so nothing forces adoption — if users don't define it, the feature exists but does nothing measurable. This is the premortem-selected failure mode: six months in, the feature is shipped but unused.
- **Concurrent final-child completions do not fire after_goal twice or skip it entirely.** Two agents finishing two sibling child tasks at the same moment must not produce duplicate PRs or a silently-missed hook execution. The design depends on the server's "is this completion finishing the parent goal?" check being race-free — i.e., serialized with the child-task Done transition under one transactional boundary, so exactly one completion sees `last child → goal complete` and gets after_goal in its response.
- **The blocking-hook execution budget does not strand goals.** The hook is blocking, so a long-running or flaky after_goal command (PR creation against a rate-limited remote, CI gates the user wires in, etc.) could leave goals stuck in In Progress beyond the hook timeout. The design depends on user-configured commands completing inside a reasonable budget (the existing 60–120s window used by before_doing / after_doing) in the common case, and on a clear re-run path for the long-tail failures.
- **The existing hook-delivery protocol absorbs the new hook without protocol-level breakage.** Bundling after_goal into the response payload alongside the existing four hooks must not change how older agents parse the array. The design depends on the array-of-hooks shape being genuinely extensible (and on the empty-hook back-compat path being implementable cleanly enough that older agents continue to complete goals without seeing after_goal).
- **Goal-to-Done latency does not become a flapping false-alarm.** The lagging SLO depends on the variability of user-defined goal-level work being bounded enough that a single p95 number is meaningful. If projects configure radically different commands (a 2-second notification vs. a 10-minute deploy), the metric stops predicting health and instead just measures workload distribution.

## Constraints

- Hook is delivered bundled in the final child task's completion / mark_reviewed response — the same response that already carries after_doing, before_review, and after_review. No new endpoint for primary delivery.
- Hook is **blocking**: the goal stays in In Progress until after_goal exits 0. If the hook fails, the goal does NOT move to Done; the agent fixes the underlying issue and re-runs.
- Goal is considered "ready for after_goal" exactly when all child tasks are in Done. Covers both `needs_review=false` (auto-Done after after_doing) and `needs_review=true` (Done after mark_reviewed).
- Back-compat: if the agent's `.stride.md` does not declare a `## after_goal` section, the server / agent treat it as an empty hook definition — the goal moves to Done unaffected, no `skills_update_required` signal needed.
- Hook protocol must match the four existing hooks: name, timeout, blocking, env, and execute_before / execute_after fields in the metadata; same `{exit_code, output, duration_ms}` result shape; same environment variable pattern (with `TASK_*` replaced by `GOAL_*` where appropriate).
- Plugin version bump required in both the `stride` skills repo and the `stride-marketplace` repo — the marketplace plugin alone is not releasable.

## Non-goals

- **Nested goals** (a goal whose child is itself a goal). v1 only handles flat parent-goal → child-task hierarchy. Sub-goal cascade semantics are deferred — the after_goal hook of an inner goal does not bubble up to its containing goal in v1.
- **Multiple `## after_goal` sections per `.stride.md`.** v1 supports exactly one after_goal command per project, following the same single-section parsing rule used by the other four hooks.
- **Per-goal customization of the after_goal command on the server.** All goals in a project share the same after_goal section. v1 does NOT support per-goal command overrides — those, if needed, come later.

## Outcome

Once shipped, goal-level work that should run exactly once per goal — a consolidated PR for a multi-task goal, a single deploy promotion, a single release note — has a consistent, protocol-blessed place to live in `.stride.md`. The current N-times-per-goal pattern (one PR per task, one deploy per task) becomes opt-out rather than opt-in: projects that adopt after_goal automatically converge to one-action-per-goal for the work types they configure, and a goal cannot reach Done while its goal-level work has not run successfully.

## Open questions

- Should after_goal expose `GOAL_*` environment variables (`GOAL_ID`, `GOAL_IDENTIFIER`, `GOAL_TITLE`, `GOAL_DESCRIPTION`, etc.) parallel to `TASK_*`? Likely yes, but the exact set is implementation detail and may grow.
- What does the failure recovery flow look like in detail? "Agent fixes and re-runs" is the high-level answer, but the API surface (re-fetch the hook? mark the failed attempt? unblock manually? expire after N attempts?) is deferred to design.
- How is the goal-to-Done latency lagging metric instrumented — server-side timer between `final after_review completed` and `goal status = done`, agent-reported `duration_ms` from the hook result, or both? The choice affects what the SLO actually measures.
- How is the adoption leading indicator instrumented — server-side scan of `.stride.md` snapshots (do agents send those?), opt-in pings from agents, or inferred from completion telemetry when after_goal hook results are reported?
