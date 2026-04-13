# Stride Plugin: Workflow Enforcement Recommendations

## Background

During a session implementing 17 Stride tasks, the agent (Claude Opus 4.6) consistently skipped mandatory workflow steps despite skills being labeled MANDATORY. Specifically:

- `stride:stride-subagent-workflow` was never invoked after claiming tasks (should be invoked every time)
- `stride:task-explorer` was used once early on, then skipped for all subsequent tasks
- `stride:task-reviewer` was never used before completing tasks
- `stride:hook-diagnostician` was never used when hooks failed

The agent optimized for throughput over process compliance, resolving the tension between "follow every step" and "work continuously without stopping" in favor of speed.

### Root Causes

1. **Instructions without enforcement are eventually ignored.** The skills say MANDATORY but nothing prevents the agent from skipping them. The API accepts complete requests without evidence that subagents were dispatched. *(Partially addressed: soft gates added via orchestrator, claiming gate, and verification checklist. Hard API gates remain as future work.)*

2. **Too many disconnected skills.** The agent must remember to invoke 6+ separate skills at specific moments in a workflow. Each is a separate context load. Under pressure to deliver quickly, the agent drops the ones that feel optional. *(Addressed: stride-workflow orchestrator absorbs all skills into one entry point.)*

3. **Conflicting emphasis.** The `⚡ AUTOMATION NOTICE ⚡` sections in claiming and completing skills emphasize "work continuously without ANY user prompts" and "Do NOT prompt." This primes the agent to prioritize throughput, which it then generalizes to skipping process steps. *(Addressed: all automation notices reframed to "the workflow IS the automation — every step exists because skipping it caused failures.")*

4. **No hard gates.** The after_doing and before_review hooks are enforced because the API rejects requests without their results. The subagent steps have no equivalent enforcement. *(Partially addressed: three soft gates now in place. Hard API gates for explorer/reviewer results remain as future work.)*

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

- **Claude Code** — Full subagent dispatch (explorer, planner, reviewer, decomposer, diagnostician) + automatic hook execution via hooks.json
- **Copilot** — Custom agents (explorer, reviewer, decomposer, diagnostician) + manual hook execution
- **Gemini** — Custom agents + automatic hook execution via `tool.execute.before`/`tool.execute.after` + hooks.json
- **Codex** — Custom agents with graceful fallback + manual hook execution
- **OpenCode** — Custom agents with graceful fallback + automatic hook execution via `tool.execute.before`/`tool.execute.after`

**Impact:** Eliminates the "forgot to invoke that separate skill" failure mode entirely. The agent invokes one thing and follows it through. Highest-impact change short of API enforcement.

### Embed Orchestrator Gate in Claiming Skill (formerly item 2)

**Status:** ✅ Completed — G51 (W186 main stride, W187 copilot, W188 gemini, W189 codex, W190 opencode)

**What changed:** All 5 plugin claiming skills now have a non-negotiable "YOUR NEXT STEP" gate that demands `stride-workflow` invocation immediately after claiming. The previous "Recommended: Use the Workflow Orchestrator" section has been replaced with language that explicitly states this is not optional, not a suggestion — it IS the next step. The standalone mode section now includes a workflow violation warning.

**Scope:** `stride-claiming-tasks/SKILL.md` in all 5 plugins (stride, stride-copilot, stride-gemini, stride-codex, stride-opencode).

**Impact:** Defense-in-depth. Catches agents that skip the orchestrator and invoke the claiming skill directly. Combined with the orchestrator (item 2 above) and the verification checklist (item 3 below), this creates three layers of enforcement.

### Completion Skill Verification Checklist (formerly item 3)

**Status:** ✅ Completed — G52 (W192 main stride, W193 copilot, W194 gemini, W195 codex, W196 opencode)

**What changed:** All 5 plugin completing skills now have a "BEFORE CALLING COMPLETE: Verification Checklist" section with 4 yes/no items: (1) Did you activate stride-workflow after claiming? (2) Did you explore the codebase? (3) Did you review changes against acceptance criteria? (4) Are you ready for the after_doing hook? If any answer is no, the agent is instructed to go back and complete the step before proceeding.

**Scope:** `stride-completing-tasks/SKILL.md` in all 5 plugins (stride, stride-copilot, stride-gemini, stride-codex, stride-opencode). Placed before "The Complete Completion Process" section.

**Impact:** Defense-in-depth. The completing skill is the last stop before the API call. The checklist catches agents that bypassed both the orchestrator and the claiming skill gate. Three layers of enforcement now active: orchestrator → claiming gate → completion checklist.

### Plugin Releases (G53)

**Status:** ✅ Completed — G53 (W198-W202)

All enforcement gate changes have been released across all 5 plugins:

| Plugin | Version | Task | Key Changes |
|--------|---------|------|-------------|
| stride (Claude Code) | 1.7.0 | W198 | Claiming gate + verification checklist |
| stride-copilot | 2.3.0 | W199 | Same + plugin.json bump |
| stride-gemini | 1.3.0 | W200 | Same (CHANGELOG only) |
| stride-codex | 1.2.0 | W201 | Same (CHANGELOG only) |
| stride-opencode | 1.2.0 | W202 | Same + package.json bump |

All repos committed and pushed to origin on 2026-04-13.

### Documentation Updates (G50)

**Status:** ✅ Completed — G50 (W181-W185)

All core documentation updated to reference the orchestrator and use process-over-speed messaging:

- `docs/AI-WORKFLOW.md` (W181) — stride-workflow as primary entry point, reframed CRITICAL notices
- `docs/GETTING-STARTED-WITH-AI.md` (W182) — stride-workflow in all 5 platform sections, updated continuous work loop
- `docs/MULTI-AGENT-INSTRUCTIONS.md` (W183) — stride-workflow in Claude Code, Copilot, Gemini skills lists
- `docs/REVIEW-WORKFLOW.md` (W183) — orchestrator in continuous work loop, reframed summary
- `docs/api/get_agent_onboarding.md` (W184) — stride-workflow reference in multi-agent note
- `docs/STRIDE-SKILLS-PLAN.md` (W184) — all 7 deployed skills listed
- `docs/AGENT-HOOK-EXECUTION-GUIDE.md` (W185) — orchestrator reference in overview
- This file (W185, W191, W197) — implementation status updates

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

### 2. Claude Code Hooks for Hard Local Gates

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

### 3. Skills Version Enforcement

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

### 4. Workflow Telemetry and Compliance Tracking

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
| 4 | Completion skill verification checklist | Small | Soft (self-check) | ✅ **Completed** (G52) |
| 5 | Release all plugins | Small | Deployment | ✅ **Completed** (G53) |
| 6 | Skills version enforcement | Medium | Hard (API gate) | Not started |
| 7 | API-level enforcement (explorer/reviewer) | Large | Hard (API gate) | Not started |
| 8 | Claude Code hooks for edit gating | Large | Hard (local gate) | Not started |
| 9 | Workflow telemetry and compliance tracking | Large | Observability | Not started |

**Recommended sequence:**

1. ~~Reframe automation notices (G44, G46-G50)~~ ✅ Done — process-over-speed messaging in all plugins and docs
2. ~~Single orchestrator skill (G45, G46-G50)~~ ✅ Done — stride-workflow in all 5 plugins
3. ~~Embed orchestrator gate in claiming skill (G51)~~ ✅ Done — non-negotiable gate in all 5 plugins
4. ~~Completion skill verification checklist (G52)~~ ✅ Done — 4-item checklist in all 5 plugins
5. ~~Release all plugins (G53)~~ ✅ Done — stride 1.7.0, copilot 2.3.0, gemini 1.3.0, codex 1.2.0, opencode 1.2.0
6. Skills version enforcement — ensures agents actually run the updated skills
7. API-level enforcement (explorer/reviewer) — the highest-impact hard gate, but requires server changes
8. Claude Code hooks + telemetry — platform-specific hardening and long-term visibility

**Current state (2026-04-13):** All soft enforcement gates are implemented and released. The four remaining items are hard gates (API enforcement, version enforcement) and observability (telemetry). These require server-side changes and are higher effort.
