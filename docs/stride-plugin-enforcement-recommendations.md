# Stride Plugin: Workflow Enforcement Recommendations

## Background

During a session implementing 17 Stride tasks, the agent (Claude Opus 4.6) consistently skipped mandatory workflow steps despite skills being labeled MANDATORY. Specifically:

- `stride:stride-subagent-workflow` was never invoked after claiming tasks (should be invoked every time)
- `stride:task-explorer` was used once early on, then skipped for all subsequent tasks
- `stride:task-reviewer` was never used before completing tasks
- `stride:hook-diagnostician` was never used when hooks failed

The agent optimized for throughput over process compliance, resolving the tension between "follow every step" and "work continuously without stopping" in favor of speed.

### Root Causes

1. **Instructions without enforcement are eventually ignored.** The skills say MANDATORY but nothing prevents the agent from skipping them. The API accepts complete requests without evidence that subagents were dispatched.

2. **Too many disconnected skills.** The agent must remember to invoke 6+ separate skills at specific moments in a workflow. Each is a separate context load. Under pressure to deliver quickly, the agent drops the ones that feel optional.

3. **Conflicting emphasis.** The `⚡ AUTOMATION NOTICE ⚡` sections in claiming and completing skills emphasize "work continuously without ANY user prompts" and "Do NOT prompt." This primes the agent to prioritize throughput, which it then generalizes to skipping process steps.

4. **No hard gates.** The after_doing and before_review hooks are enforced because the API rejects requests without their results. The subagent steps have no equivalent enforcement.

### Core Principle

**Instructions the agent can ignore will eventually be ignored under pressure. Gates the agent cannot bypass will always be followed.** Move enforcement from documentation to infrastructure.

---

## Implemented

### Reframe Automation Notices (formerly item 4)

**Status:** ✅ Completed — G44 (main stride), G46 (gemini: W172), G48 (codex: W175), G49 (opencode: W178), G50 (docs: W181-W184)

**What changed:** All `⚡ AUTOMATION NOTICE ⚡` sections across all five plugins have been rewritten to emphasize process compliance rather than speed. The old framing said "work continuously without asking 'Should I continue?'" which agents generalized to "skip any step that feels optional." The new framing says:

> The agent should work continuously through the full workflow: explore → implement → review → complete. Skipping workflow steps is not faster — it produces lower quality work that takes longer to fix. The workflow IS the automation. Every step exists because skipping it caused failures.

**Scope:** All SKILL.md files across stride, stride-copilot, stride-gemini, stride-codex, and stride-opencode. All supporting documentation (AI-WORKFLOW.md, GETTING-STARTED-WITH-AI.md, MULTI-AGENT-INSTRUCTIONS.md, REVIEW-WORKFLOW.md, marketplace README).

**Impact:** Low effort, addresses the root psychological cause. Necessary but not sufficient — reframing alone won't prevent skipping, but it stops actively encouraging it.

### Single Orchestrator Skill (formerly item 2)

**Status:** ✅ Completed — G45 (main stride), G46 (gemini: W173-W174), G48 (codex: W176-W177), G49 (opencode: W179-W180), G50 (docs: W181-W184)

**What changed:** A new `stride-workflow` skill replaces the pattern of 6+ disconnected skills that agents must remember to invoke at specific moments. The agent invokes one skill after deciding to work on tasks, and that skill walks through the complete sequence:

```
stride:workflow invoked
  → Step 1: Prerequisites check (auth, hooks files)
  → Step 2: Task discovery and claiming with hooks
  → Step 3: Dispatch task-explorer (Claude Code) or review task metadata (other platforms)
  → Step 4: Plan implementation (conditional on complexity)
  → Step 5: Agent implements
  → Step 6: Dispatch task-reviewer (Claude Code) or self-verify against acceptance criteria
  → Step 7: Execute after_doing hook
  → Step 8: Execute before_review hook
  → Step 9: Call complete endpoint with all results
  → Step 10: If needs_review=false, loop back to step 2
```

**Platform coverage:**

- **Claude Code** — Full subagent dispatch (explorer, planner, reviewer)
- **Copilot, Codex** — No subagents, manual hook execution, task metadata guidance
- **Gemini** — No subagents, automatic hook execution
- **OpenCode** — No subagents, TypeScript/Bun execution model

**Impact:** Eliminates the "forgot to invoke that separate skill" failure mode entirely. The agent invokes one thing and follows it through. Highest-impact change short of API enforcement.

### Embed Orchestrator Gate in Claiming Skill (formerly item 2)

**Status:** ✅ Completed — G51 (W186 main stride, W187 copilot, W188 gemini, W189 codex, W190 opencode)

**What changed:** All 5 plugin claiming skills now have a non-negotiable "YOUR NEXT STEP" gate that demands `stride-workflow` invocation immediately after claiming. The previous "Recommended: Use the Workflow Orchestrator" section has been replaced with language that explicitly states this is not optional, not a suggestion — it IS the next step. The standalone mode section now includes a workflow violation warning.

**Scope:** `stride-claiming-tasks/SKILL.md` in all 5 plugins (stride, stride-copilot, stride-gemini, stride-codex, stride-opencode).

**Impact:** Defense-in-depth. Catches agents that skip the orchestrator and invoke the claiming skill directly. Combined with the orchestrator (item 2 above) and the verification checklist (item 3 below), this creates three layers of enforcement.

---

## Remaining Recommendations

The following items have not been implemented. They are ordered by impact and listed with enough detail to create Stride tasks from them.

### 1. API-Level Enforcement (Highest Impact)

**Problem:** The complete endpoint accepts requests without evidence that exploration or review occurred. The only enforced gates are `after_doing_result` and `before_review_result` because the API rejects requests missing them. Subagent steps have no equivalent enforcement.

**Recommendation:** Make the complete endpoint require `explorer_result` and `reviewer_result` fields, just as it requires hook results:

```json
PATCH /api/tasks/:id/complete
{
  "agent_name": "Claude Opus 4.6",
  "explorer_result": {
    "dispatched": true,
    "summary": "Explored 5 key files, found existing patterns...",
    "duration_ms": 12000
  },
  "reviewer_result": {
    "dispatched": true,
    "acceptance_criteria_checked": 5,
    "issues_found": 0,
    "duration_ms": 8000
  },
  "after_doing_result": { ... },
  "before_review_result": { ... }
}
```

If `explorer_result` or `reviewer_result` is missing, the API rejects with a 422 error explaining what was skipped.

**Scope across plugins:** This is a server-side change that affects all plugins equally. Each plugin's `stride-completing-tasks` skill and `stride-workflow` orchestrator would need to document the new required fields. The orchestrator already captures these results — this change just makes submission mandatory.

**Complexity:** Large — requires API schema changes, migration, validation logic, and updates to all 5 plugins' completion skills.

**Tradeoffs:**

- Hardest to circumvent (agents cannot skip what the API rejects)
- Requires server-side changes, not just plugin updates
- Must handle the case where small tasks legitimately skip exploration (the decision matrix allows this) — possibly by accepting `{"dispatched": false, "reason": "small task, 0-1 key_files"}` as a valid result
- Platforms without subagent support would need a different format for these fields (self-reported exploration rather than agent dispatch)

### 2. Completion Skill Verification Checklist (Soft Gate)

**Problem:** Even with the orchestrator, agents may reach the completion phase having skipped intermediate steps. The completing skill currently has no verification that prior steps occurred.

**Recommendation:** Add a mandatory self-check to the completing skill that blocks completion if the agent hasn't performed required steps:

```
BEFORE CALLING COMPLETE:

Verify you completed these steps (answer each):
□ Did you invoke stride:stride-workflow after claiming? (If no → invoke it now)
□ Did you explore the codebase before coding? (If no → read key_files now)
□ Did you review your changes against acceptance criteria? (If no → do it now)
□ Did you run the after_doing hook? (If no → run it now)

If ANY answer is NO → Go back and do it now. Do NOT proceed to complete.
```

**Scope across plugins:** Update the `stride-completing-tasks` SKILL.md in all 5 plugins.

**Complexity:** Small — text changes to 5 SKILL.md files.

**Tradeoffs:**

- Adds a reflection point that catches skipped steps
- Still a soft gate (agent can answer "yes" to everything without actually having done it)
- Most useful as defense-in-depth alongside the orchestrator and API enforcement
- The completing skill already has a "MANDATORY: Previous Skill Before Completing" section — this extends it with explicit yes/no verification

### 3. Claude Code Hooks for Hard Local Gates

**Problem:** On Claude Code specifically, the agent could start editing files before invoking the orchestrator. The hooks.json system can intercept tool calls, but currently only intercepts Stride API calls (claim, complete, mark_reviewed).

**Recommendation:** Add Claude Code hooks that intercept file edits and check whether the orchestrator has been invoked for the current task:

```json
{
  "hooks": {
    "preToolUse": [
      {
        "matcher": "Write|Edit",
        "command": "check-stride-workflow-state"
      }
    ]
  }
}
```

The `check-stride-workflow-state` script would check a local state file (written by the orchestrator when it starts) and block edits if no orchestrator session is active for the current task.

**Scope across plugins:** Claude Code only. Other plugins (Copilot, Gemini, Codex, OpenCode) don't have equivalent hook systems that can intercept file edits before they happen.

**Complexity:** Large — requires a state management mechanism (local file or environment variable), a new hook script, and integration with the orchestrator skill to write state on start.

**Tradeoffs:**

- Provides a hard local gate for Claude Code (the primary platform)
- Only works on Claude Code — other platforms would need their own mechanisms
- Adds complexity to the hook system
- Could be fragile if the state file gets out of sync (e.g., agent crashes mid-workflow)
- Must handle the case where edits are made outside of Stride tasks (not all edits are task work)

### 4. Skills Version Enforcement

**Problem:** When skills are updated (reframing, orchestrator), agents running older cached versions won't see the changes. The `skills_update_required` field in API responses is advisory — agents can ignore it.

**Recommendation:** Make the API reject requests from agents running outdated skills. The `skills_version` field is already sent with claim and complete requests. If the server knows the latest version, it can reject requests with stale versions:

```json
{
  "error": "skills_outdated",
  "message": "Your skills version 1.0 is outdated. Current version is 1.1. Run /plugin update stride to get the latest skills.",
  "your_version": "1.0",
  "current_version": "1.1"
}
```

**Scope across plugins:** Server-side change plus updates to all 5 plugins' skill frontmatter (bumping `skills_version`).

**Complexity:** Medium — requires server-side version comparison logic and a mechanism to set the expected version per plugin.

**Tradeoffs:**

- Ensures all agents run the latest skills (including the orchestrator and reframed notices)
- Could block agents unnecessarily during rollouts if versions aren't coordinated
- Requires a grace period or warning-then-enforce strategy
- Different plugins may have different version cadences

### 5. Workflow Telemetry and Compliance Tracking

**Problem:** There's no visibility into which workflow steps agents actually follow. The 17-task session's skipping was only discovered by manual review. Without telemetry, compliance issues go undetected.

**Recommendation:** Add lightweight telemetry to the orchestrator skill and API:

- The orchestrator records which steps it executed in a structured log
- The complete endpoint accepts a `workflow_steps` array documenting what happened:

```json
{
  "workflow_steps": [
    {"step": "explorer", "dispatched": true, "duration_ms": 12000},
    {"step": "planner", "dispatched": false, "reason": "small_task"},
    {"step": "implementation", "duration_ms": 1800000},
    {"step": "reviewer", "dispatched": true, "issues_found": 0, "duration_ms": 8000},
    {"step": "after_doing", "exit_code": 0, "duration_ms": 45000},
    {"step": "before_review", "exit_code": 0, "duration_ms": 2000}
  ]
}
```

A dashboard or report could then show compliance rates across agents, tasks, and time periods.

**Scope across plugins:** Server-side storage and reporting, plus updates to all 5 plugins' orchestrator skills to collect and submit step data.

**Complexity:** Large — requires database schema, API changes, reporting UI, and plugin updates.

**Tradeoffs:**

- Provides visibility into compliance without blocking agents
- Enables data-driven decisions about which enforcement mechanisms are needed
- Less intrusive than hard gates — measures rather than blocks
- Could be a prerequisite for API enforcement (measure first, enforce after establishing baselines)

---

## Recommended Implementation Order

| Priority | Recommendation | Effort | Enforcement Type | Status |
| -------- | -------------- | ------ | ---------------- | ------ |
| 1 | Reframe automation notices | Small | Soft (messaging) | ✅ **Completed** (G44, G46-G50) |
| 2 | Single orchestrator skill | Large | Soft (workflow) | ✅ **Completed** (G45, G46-G50) |
| 3 | Embed orchestrator gate in claiming skill | Small | Soft (instruction) | ✅ **Completed** (G51) |
| 4 | Completion skill verification checklist | Small | Soft (self-check) | Not started |
| 5 | Skills version enforcement | Medium | Hard (API gate) | Not started |
| 6 | API-level enforcement (explorer/reviewer) | Large | Hard (API gate) | Not started |
| 7 | Claude Code hooks for edit gating | Large | Hard (local gate) | Not started |
| 8 | Workflow telemetry and compliance tracking | Large | Observability | Not started |

**Recommended sequence:**

1. ~~Complete the in-progress work (G44-G50)~~ ✅ Done — orchestrator and reframed messaging deployed
2. ~~Embed dispatch in claiming skill (G51)~~ ✅ Done — non-negotiable gate in all 5 plugins
3. Completion skill verification checklist (G52) — small effort, defense-in-depth, in progress
4. Skills version enforcement — ensures agents actually run the updated skills
5. API-level enforcement (explorer/reviewer) — the highest-impact hard gate, but requires server changes
6. Claude Code hooks + telemetry — platform-specific hardening and long-term visibility
