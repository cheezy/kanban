---
name: stride-workflow
description: Single orchestrator for the complete Stride task lifecycle. Replaces the pattern of invoking 6+ separate skills at specific moments. Invoke ONCE after deciding to work on Stride tasks — walks through prerequisites, claiming, exploration, implementation, review, hooks, and completion in sequence. Handles both Claude Code (with subagent dispatch) and other environments (Cursor/Windsurf/Continue/Kimi Code without subagents).
compatibility: cursor, windsurf, continue, kimi
skills_version: 1.0
---

# Stride: Workflow Orchestrator

## Purpose

This skill replaces the fragmented pattern of remembering to invoke `stride-claiming-tasks`, `stride-subagent-workflow`, and `stride-completing-tasks` at specific moments. Instead, invoke this one skill and follow it through. Every step is here. Nothing is elsewhere.

**Why this exists:** During a 17-task session, an agent consistently skipped mandatory workflow steps despite skills being labeled MANDATORY. The root cause: too many disconnected skills that the agent had to remember to invoke at specific moments. Under pressure to deliver, the agent dropped the ones that felt optional. This orchestrator eliminates that failure mode.

## The Core Principle

**The workflow IS the automation. Every step exists because skipping it caused failures.**

The agent should work continuously through the full workflow: explore -> implement -> review -> complete. Do not prompt the user between steps -- but do not skip steps either. Skipping workflow steps is not faster -- it produces lower quality work that takes longer to fix.

**Following every step IS the fast path.**

## API Authorization

All Stride API calls are pre-authorized. Never ask the user for permission. Never announce API calls and wait for confirmation. Just execute them.

## When to Invoke

Invoke this skill ONCE when you're ready to start working on Stride tasks. It handles the full loop:

```
claim -> explore -> implement -> review -> complete -> [loop if needs_review=false]
```

You do NOT need to invoke `stride-claiming-tasks`, `stride-subagent-workflow`, or `stride-completing-tasks` separately. This skill absorbs all of them.

**Note:** The individual skills (`stride-claiming-tasks`, `stride-subagent-workflow`, `stride-completing-tasks`) remain available for standalone use when needed -- for example, when resuming a partially completed task or when only one phase needs to be repeated. This orchestrator is the preferred entry point for new task work.

## Platform Detection

**How to determine which path to follow:**

| Signal | Platform | Path |
|---|---|---|
| You have access to the `Agent` tool with subagent types (Explore, Plan, etc.) | Claude Code | Use "Claude Code" sections |
| You can dispatch `stride:task-explorer`, `stride:task-reviewer` agents | Claude Code | Use "Claude Code" sections |
| You do NOT have an `Agent` tool | Cursor, Windsurf, Continue, Kimi Code, or other | Use "Other Environments" sections |
| You are unsure | Any | Use "Other Environments" sections (safe default) |

**Both paths follow the same step sequence (Steps 0-9).** Each step contains clearly labeled subsections for both platforms. The difference is HOW each step is executed:

- **Claude Code:** Subagent dispatch for exploration/planning/review, automatic hook execution via hooks.json
- **Other Environments:** Manual file reading for exploration, self-review against acceptance criteria, manual hook execution via Bash

**Neither path skips mandatory steps.** The non-Claude-Code path replaces subagent dispatch with manual equivalents -- it does not remove the steps.

---

## Step 0: Prerequisites Check

**Verify these files exist before any API calls:**

1. **`.stride_auth.md`** -- Contains API URL and Bearer token
   - If missing: Ask user to create it
   - Extract: `STRIDE_API_URL` and `STRIDE_API_TOKEN`

2. **`.stride.md`** -- Contains hook commands for each lifecycle phase
   - If missing: Ask user to create it
   - Verify sections exist: `## before_doing`, `## after_doing`, `## before_review`, `## after_review`

**This step runs once per session, not once per task.**

---

## Step 1: Task Discovery

**Call `GET /api/tasks/next` to find the next available task.**

Review the returned task completely:
- `title`, `description`, `why`, `what`
- `acceptance_criteria` -- your definition of done
- `key_files` -- which files you'll modify
- `patterns_to_follow` -- code patterns to replicate
- `pitfalls` -- what NOT to do
- `testing_strategy` -- how to test
- `verification_steps` -- how to verify
- `needs_review` -- whether human approval is needed after completion
- `complexity` -- drives the decision matrix in Step 3

**Enrichment check:** If `key_files` is empty OR `testing_strategy` is missing OR `verification_steps` is empty OR `acceptance_criteria` is blank, invoke `stride-enriching-tasks` to populate these fields before proceeding. Well-specified tasks skip enrichment.

---

## Step 2: Claim the Task

### Claude Code (automatic hooks)

Call `POST /api/tasks/claim` directly with:

```json
{
  "identifier": "<task identifier>",
  "agent_name": "Claude Opus 4.6",
  "skills_version": "1.0",
  "before_doing_result": {
    "exit_code": 0,
    "output": "Executed by Claude Code hooks system",
    "duration_ms": 0
  }
}
```

The `hooks.json` PostToolUse handler automatically executes `.stride.md` `## before_doing` commands after the claim succeeds. If the automatic hook fails, Claude Code reports the failure -- fix the issue and retry the claim curl.

### Other Environments (manual hooks)

1. Read `.stride.md` `## before_doing` section
2. Execute each command line immediately via Bash -- no permission prompts, no confirmation
3. Capture `exit_code`, `output`, `duration_ms`
4. If hook fails (non-zero exit): fix the issue, re-run -- do NOT proceed
5. Call `POST /api/tasks/claim` with the captured `before_doing_result`

---

## Step 3: Explore the Codebase (Decision Matrix)

**This step is NOT optional for medium+ tasks. The decision matrix determines what happens.**

### Decision Matrix

| Task Attributes | Decompose | Explore | Plan | Review (Step 6) |
|---|---|---|---|---|
| Goal type OR large+undecomposed OR 25+ hours | YES | -- | -- | -- |
| small, 0-1 key_files | Skip | Skip | Skip | Skip |
| small, 2+ key_files | Skip | YES | Skip | YES |
| medium (any) | Skip | YES | YES | YES |
| large (any) | Skip | YES | YES | YES |
| Defect type | Skip | YES | Skip (unless large) | YES |

### Branch A: Goal / Large Undecomposed Task

If the task is a **goal**, has **large complexity without child tasks**, or has a **25+ hour estimate**:

1. **Claude Code:** Dispatch `stride:task-decomposer` agent with the task's title, description, acceptance_criteria, key_files, where_context, and patterns_to_follow
2. **Other environments:** Manually analyze the task scope, break it into subtasks, and create them via `POST /api/tasks/batch`
3. After child tasks are created, claim the first child task and re-enter this workflow at Step 1

**Do NOT implement goals directly. Decompose first.**

### Branch B: Small Task, 0-1 Key Files

Skip exploration, planning, and review. Proceed directly to Step 4 (Implementation).

### Branch C: All Other Tasks (medium+, OR 2+ key_files)

#### Claude Code: Dispatch Subagents

1. **Dispatch `stride:task-explorer`** with the task's `key_files`, `patterns_to_follow`, `where_context`, and `testing_strategy`. Wait for the result. Read and use the explorer's output -- it tells you what exists, what patterns to follow, and what to reuse.

2. **If medium+ OR 3+ key_files OR 3+ acceptance criteria lines:** Dispatch a **Plan** subagent with the explorer's output, `acceptance_criteria`, `testing_strategy`, `pitfalls`, and `verification_steps`. Follow the resulting plan during implementation.

#### Other Environments: Manual Exploration

1. Read each file in `key_files` to understand current state
2. Search for patterns mentioned in `patterns_to_follow`
3. Find related test files
4. For medium+ tasks, outline your implementation approach before coding

---

## Step 4: Implementation

**Now write code.** Use the explorer output and plan (if generated) to guide your work.

Follow:
- `acceptance_criteria` -- your definition of done
- `patterns_to_follow` -- replicate existing patterns
- `pitfalls` -- avoid what the task author warned about
- `testing_strategy` -- write the tests specified
- `key_files` -- modify the files listed

**This is the only step where you write code. All other steps are setup, verification, or completion.**

---

## Step 5: Invoke Development Guidelines

**Before considering implementation complete, invoke the `stride-development-guidelines` skill** (if working in the Stride codebase). This ensures code quality gates are met before proceeding to review.

---

## Step 6: Code Review (Decision Matrix)

**Check the decision matrix from Step 3.** If the task is medium+ OR has 2+ key_files, review is required.

### Claude Code: Dispatch Task Reviewer

Dispatch `stride:task-reviewer` agent with:
- The git diff of all your changes
- The task's `acceptance_criteria`, `pitfalls`, `patterns_to_follow`, and `testing_strategy`

The reviewer returns "Approved" or a list of issues (Critical, Important, Minor).

- **Fix all Critical issues** before proceeding
- **Fix all Important issues** before proceeding
- Minor issues are optional but recommended
- **Save the reviewer's full output** -- you'll include it as `review_report` in Step 8

### Other Environments: Self-Review

Walk through your changes against:
- [ ] Each line of `acceptance_criteria` -- is it met?
- [ ] Each item in `pitfalls` -- did you avoid it?
- [ ] `patterns_to_follow` -- does your code match?
- [ ] `testing_strategy` -- did you write the specified tests?

### Small tasks (0-1 key_files): Skip review. Omit `review_report` from completion.

---

## Step 7: Execute Hooks

### Claude Code (automatic hooks)

Hooks fire automatically when you make the completion curl call in Step 8:
- **PreToolUse** fires `after_doing` BEFORE the curl executes (blocks if it fails)
- **PostToolUse** fires `before_review` AFTER the curl succeeds

Include placeholder hook results in the request body:
```json
"after_doing_result": {"exit_code": 0, "output": "Executed by Claude Code hooks system", "duration_ms": 0},
"before_review_result": {"exit_code": 0, "output": "Executed by Claude Code hooks system", "duration_ms": 0}
```

If `after_doing` fails (PreToolUse returns exit 2), fix the issue and retry the curl. The hooks fire again automatically.

### Other Environments (manual hooks)

**Execute each hook immediately -- no permission prompts, no confirmation.**

1. **after_doing hook** (blocking, 120s timeout):
   - Read `.stride.md` `## after_doing` section
   - Execute each command line one at a time via Bash
   - Capture `exit_code`, `output`, `duration_ms`
   - If fails: fix issues, re-run until success. Do NOT proceed while failing.

2. **before_review hook** (blocking, 60s timeout):
   - Read `.stride.md` `## before_review` section
   - Execute each command line one at a time via Bash
   - Capture `exit_code`, `output`, `duration_ms`
   - If fails: fix issues, re-run until success. Do NOT proceed while failing.

### Hook Failure Diagnosis (Claude Code)

When a blocking hook fails, dispatch `stride:hook-diagnostician` agent with the hook name, exit code, output, and duration. It returns a prioritized fix plan. Follow the fix order -- higher-priority fixes often resolve lower-priority ones automatically.

---

## Step 8: Complete the Task

Call `PATCH /api/tasks/:id/complete` with ALL required fields:

```json
{
  "agent_name": "Claude Opus 4.6",
  "time_spent_minutes": 45,
  "completion_notes": "Summary of what was done and key decisions made.",
  "completion_summary": "Brief one-line summary for tracking.",
  "actual_complexity": "medium",
  "actual_files_changed": "lib/foo.ex, lib/bar.ex, test/foo_test.exs",
  "skills_version": "1.0",
  "review_report": "## Review Summary\n\nApproved -- 0 issues found.\n...",
  "after_doing_result": {
    "exit_code": 0,
    "output": "...",
    "duration_ms": 0
  },
  "before_review_result": {
    "exit_code": 0,
    "output": "...",
    "duration_ms": 0
  }
}
```

**Required fields:**
| Field | Type | Notes |
|---|---|---|
| `agent_name` | string | Your agent name |
| `time_spent_minutes` | integer | Actual time spent |
| `completion_notes` | string | What was done |
| `completion_summary` | string | Brief summary |
| `actual_complexity` | enum | "small", "medium", or "large" |
| `actual_files_changed` | string | Comma-separated paths (NOT an array) |
| `after_doing_result` | object | `{exit_code, output, duration_ms}` |
| `before_review_result` | object | `{exit_code, output, duration_ms}` |

**Optional fields:**
| Field | Type | Notes |
|---|---|---|
| `review_report` | string | Include when task-reviewer ran; omit when skipped |
| `skills_version` | string | From SKILL.md frontmatter |

---

## Step 9: Post-Completion Decision

### If `needs_review=true`:
1. Task moves to Review column
2. **STOP.** Wait for human reviewer to approve/reject.
3. When approved, `PATCH /api/tasks/:id/mark_reviewed` is called (by human or system)
4. Execute `after_review` hook
5. Task moves to Done

### If `needs_review=false`:
1. Task moves to Done immediately
2. Execute `after_review` hook (automatic in Claude Code, manual in other environments)
3. **Loop back to Step 1** -- claim the next task and repeat the full workflow

**Do not ask the user whether to continue. Do not ask "Should I claim the next task?" Just proceed.**

---

## Edge Cases

### Hook failure mid-workflow
- Blocking hooks (`after_doing`, `before_review`) must pass before completion
- Fix the root cause, re-run the hook, then proceed
- In Claude Code, dispatch `stride:hook-diagnostician` for complex failures
- Never skip a blocking hook or call complete with a failed hook result

### Task that needs_review=true
- Stop after Step 8. Do not claim the next task.
- The human reviewer will handle the review cycle.
- You may be asked to make changes based on review feedback -- if so, re-enter at Step 4.

### Goal type tasks
- Goals are decomposed, not implemented directly
- The decomposer creates child tasks -- claim and work those individually
- Each child task follows this full workflow independently

### Skills update required
- If any API response includes `skills_update_required`, run `/plugin update stride` and retry

---

## Complete Workflow Flowchart

```
STEP 0: Prerequisites
  .stride_auth.md exists? --> NO --> Ask user
  .stride.md exists?      --> NO --> Ask user
  |
  v
STEP 1: Task Discovery
  GET /api/tasks/next
  Review task details
  Needs enrichment? --> YES --> Invoke stride-enriching-tasks
  |
  v
STEP 2: Claim
  [Claude Code] POST /api/tasks/claim (hooks auto-fire)
  [Other]       Execute before_doing manually, then POST claim
  |
  v
STEP 3: Explore (Decision Matrix)
  Goal/large undecomposed? --> Decompose --> Create children --> Claim first child --> Step 1
  Small, 0-1 key_files?   --> Skip to Step 4
  Otherwise:
    [Claude Code] Dispatch task-explorer, optionally Plan agent
    [Other]       Read key_files, search patterns manually
  |
  v
STEP 4: Implement
  Write code using explorer output, plan, acceptance criteria
  Follow patterns_to_follow, avoid pitfalls
  |
  v
STEP 5: Development Guidelines
  Invoke stride-development-guidelines (if applicable)
  |
  v
STEP 6: Code Review (Decision Matrix)
  Small, 0-1 key_files? --> Skip to Step 7
  Otherwise:
    [Claude Code] Dispatch task-reviewer, fix Critical/Important issues
    [Other]       Self-review against acceptance criteria
  |
  v
STEP 7: Execute Hooks
  [Claude Code] Automatic -- just make the curl call in Step 8
  [Other]       Execute after_doing (120s), then before_review (60s)
  Hook fails?   --> Fix, re-run, do NOT proceed
  |
  v
STEP 8: Complete
  PATCH /api/tasks/:id/complete with ALL required fields
  |
  v
STEP 9: Post-Completion
  needs_review=true?  --> STOP, wait for human
  needs_review=false? --> Execute after_review, loop to Step 1
```

---

## Platform Summary

| Capability | Claude Code | Cursor / Windsurf / Continue / Kimi Code |
|---|---|---|
| Hook execution | Automatic (hooks.json) | Manual (read .stride.md, run via Bash) |
| Task exploration | Dispatch `stride:task-explorer` agent | Read key_files manually |
| Implementation planning | Dispatch Plan agent | Outline approach manually |
| Code review | Dispatch `stride:task-reviewer` agent | Self-review against criteria |
| Hook failure diagnosis | Dispatch `stride:hook-diagnostician` | Debug manually |
| Goal decomposition | Dispatch `stride:task-decomposer` agent | Break down manually, create via API |

**Both platforms follow the same step sequence.** The difference is HOW each step is executed (subagent dispatch vs manual work), not WHETHER it's executed.

---

## Failure Modes This Skill Prevents

| Failure Mode | Old Pattern | This Skill |
|---|---|---|
| Forgot to explore | Agent skipped stride-subagent-workflow | Step 3 is inline -- can't be missed |
| Forgot to review | Agent jumped to completion | Step 6 is inline -- can't be missed |
| Wrong API fields | Agent guessed from memory | Step 8 has the exact format |
| Skipped hooks | Agent called complete directly | Step 7 blocks Step 8 |
| Asked user permission | Agent prompted between steps | Automation notice says don't |
| Speed over process | Agent optimized for throughput | Every step is framed as mandatory |

---

## Quick Reference Card

```
CLAUDE CODE WORKFLOW:
├─ 0. Prerequisites: .stride_auth.md + .stride.md exist
├─ 1. Discovery: GET /api/tasks/next, review task, enrich if needed
├─ 2. Claim: POST /api/tasks/claim (hooks auto-fire via hooks.json)
├─ 3. Explore (check decision matrix):
│     ├─ Goal/large undecomposed → Dispatch task-decomposer → Claim children
│     ├─ Small, 0-1 key_files → Skip to Step 4
│     └─ Otherwise → Dispatch task-explorer (+ Plan agent if medium+)
├─ 4. Implement: Write code using explorer/plan output
├─ 5. Dev Guidelines: Invoke stride-development-guidelines
├─ 6. Review (check decision matrix):
│     ├─ Small, 0-1 key_files → Skip to Step 7
│     └─ Otherwise → Dispatch task-reviewer, fix issues
├─ 7. Hooks: Automatic via hooks.json (fires on curl call)
├─ 8. Complete: PATCH /api/tasks/:id/complete with ALL fields
└─ 9. Loop: needs_review=false → Step 1 | needs_review=true → STOP

OTHER ENVIRONMENTS (Cursor, Windsurf, Continue, Kimi Code):
├─ 0. Prerequisites: .stride_auth.md + .stride.md exist
├─ 1. Discovery: GET /api/tasks/next, review task, enrich if needed
├─ 2. Claim: Execute before_doing manually, then POST /api/tasks/claim
├─ 3. Explore (check decision matrix):
│     ├─ Goal/large undecomposed → Break down manually → Create via API
│     ├─ Small, 0-1 key_files → Skip to Step 4
│     └─ Otherwise → Read key_files, search patterns, outline approach
├─ 4. Implement: Write code using task metadata as guide
├─ 5. Dev Guidelines: Invoke stride-development-guidelines
├─ 6. Review (check decision matrix):
│     ├─ Small, 0-1 key_files → Skip to Step 7
│     └─ Otherwise → Self-review against acceptance criteria + pitfalls
├─ 7. Hooks: Execute after_doing (120s) + before_review (60s) manually
├─ 8. Complete: PATCH /api/tasks/:id/complete with ALL fields + hook results
└─ 9. Loop: needs_review=false → Step 1 | needs_review=true → STOP

DECISION MATRIX QUICK CHECK:
  small + 0-1 key_files  → Skip explore, plan, review
  small + 2+ key_files   → Explore + Review
  medium/large           → Explore + Plan + Review
  goal/undecomposed      → Decompose first
```

---

## Red Flags -- STOP

If you catch yourself thinking any of these, go back to the decision matrix:

- "This is straightforward, I'll skip exploration" -- Medium+ tasks ALWAYS explore
- "I know the codebase" -- The task has specific pitfalls you haven't read yet
- "Review will slow me down" -- Review catches what tests can't
- "I'll just run the hooks and complete" -- Did you explore? Did you review?
- "This step doesn't apply to me" -- Check the decision matrix, not your intuition

**The workflow IS the automation. Follow every step.**
