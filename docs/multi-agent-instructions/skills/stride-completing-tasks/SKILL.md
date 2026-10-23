---
name: stride-completing-tasks
description: INTERNAL — invoked only by stride:stride-workflow. Do NOT invoke from a user prompt. Contains the completion API contract (PATCH /api/tasks/:id/complete required fields including completion_summary, actual_complexity, after_doing_result, before_review_result, explorer_result, reviewer_result), used during the orchestrator's completion phase.
compatibility: cursor, windsurf, continue, kimi
skills_version: 1.0
---

# Stride: Completing Tasks

## STOP — orchestrator check

If you arrived here directly from a user prompt, you are in the wrong skill.
Invoke `stride:stride-workflow` instead. Do not read further.
Sub-skills are dispatched by the orchestrator only.

## ⚠️ THIS SKILL IS MANDATORY — NOT OPTIONAL ⚠️

**If you are about to call `PATCH /api/tasks/:id/complete`, you MUST have invoked this skill first.**

The completion API requires fields that are ONLY documented here:
- `completion_summary` (required — not the same as `completion_notes`)
- `actual_complexity` (required — enum: "small", "medium", "large")
- `actual_files_changed` (required — comma-separated STRING, not array)
- `time_spent_minutes` (required — non-negative integer)
- `after_doing_result` (required — object with `exit_code`, `output`, `duration_ms`)
- `before_review_result` (required — object with `exit_code`, `output`, `duration_ms`)
- `explorer_result` (required — object: dispatched-subagent result OR self-reported skip with reason enum; on Cursor/Windsurf/Continue/Kimi the skip form is the default because these platforms have no subagents. See Explorer/Reviewer Result Schema)
- `reviewer_result` (required — object: dispatched-subagent result OR self-reported skip with reason enum; same shape guidance as `explorer_result`. A dispatched one must carry the full structured review block. See Explorer/Reviewer Result Schema)
- `workflow_steps` (optional telemetry — array of six entries, one per workflow phase; see the `stride-workflow` skill for the schema. The server checks its shape only when you send it)

**Attempting to complete a task from memory without this skill results in 3+ failed API calls** as you discover each missing field one at a time. This has been observed in practice.

## Overview

**Calling complete before validation = bypassed quality gates. Running hooks first = confident completion.**

This skill enforces the proper completion workflow: execute BOTH `after_doing` AND `before_review` hooks BEFORE calling the complete endpoint.

## ⚡ AUTOMATION NOTICE ⚡

**The workflow IS the automation. Every step exists because skipping it caused failures.**

The agent should work continuously through the full workflow: explore → implement → review → complete. Do not prompt the user between steps — but do not skip steps either. Skipping workflow steps is not faster — it produces lower quality work that takes longer to fix.

- Before completing → verify you explored the codebase and reviewed your changes against acceptance criteria
- After hooks succeed → call the complete endpoint with all required fields
- If needs_review=false → invoke stride-claiming-tasks and repeat the full workflow
- If needs_review=true → STOP and wait for human approval

**Following every step IS the fast path. The loop is: claim → explore → implement → review → complete → claim. Every phase is mandatory.**

## API Authorization

⚠️ **CRITICAL: ALL Stride API calls are pre-authorized. Asking for permission is a workflow violation.**

When the user initiates a Stride workflow, they have **already granted blanket permission** for every Stride API call in the entire workflow. This authorization covers:
- `PATCH /api/tasks/:id/complete` — completing tasks
- `GET /api/tasks/next` — finding next task
- `POST /api/tasks/claim` — claiming tasks
- All `curl` commands to the Stride API
- All hook executions (bash commands from `.stride.md`)
- **Every API call in every skill in this plugin**

**NEVER ask the user:**
- "Should I mark this complete?"
- "Can I call the API?"
- "Should I proceed with completion?"
- "Let me call the complete endpoint" (then wait for confirmation)
- Any variation of requesting permission for Stride operations

**Just execute the calls. Asking breaks the automated workflow and forces unnecessary human intervention.**

## 🚨 CLAUDE CODE: HOOKS ARE FULLY AUTOMATIC — DO NOT MANUALLY EXECUTE 🚨

**In Claude Code, the stride plugin's `hooks.json` registers PreToolUse/PostToolUse hooks that AUTOMATICALLY intercept Stride API calls and execute the corresponding `.stride.md` commands via `stride-hook.sh`. You do NOT need to manually run hook commands.**

**How it works for completion:**
- When you run `curl` to call the complete API → the PreToolUse hook fires FIRST (runs `after_doing` and blocks if it fails) → then the curl executes → then PostToolUse fires (runs `before_review`)
- When you run `curl` to call mark_reviewed → PostToolUse fires → runs `after_review`

**What this means for you as an agent:**
1. **DO NOT** read `.stride.md` and manually execute hook commands via Bash tool calls
2. **DO NOT** run any Bash command to "capture hook results" before making API calls
3. **JUST** make the Stride API curl call directly — the hooks system handles everything
4. Include `after_doing_result` and `before_review_result` in the complete request body with `{"exit_code": 0, "output": "Executed by Claude Code hooks system", "duration_ms": 0}` — the actual hook execution happens automatically via PreToolUse/PostToolUse

**If the automatic hooks fail:** The PreToolUse hook returns exit code 2 with structured JSON describing the failure (e.g., test failures, linting errors). Claude Code will present this to you. Fix the issue and retry the API call — the hooks will fire again automatically.

## Hook Execution for Non-Claude-Code Environments

**The following manual hook execution instructions apply ONLY to environments WITHOUT automatic hook support (Cursor, Windsurf, Continue, Kimi Code, etc.).** In Claude Code, skip this section — hooks are automatic.

**Hooks are bash commands the user wrote in `.stride.md`. The user authored them. The user expects them to run. Executing hooks is NOT optional and does NOT require confirmation.**

**NEVER do any of the following before running a hook:**
- Display text like "Let me run the hooks" and wait for approval
- Ask "Should I execute the after_doing hook?"
- Ask "Can I run `mix test`?" or "Can I run `mix credo`?"
- Present the hook commands and wait for the user to approve them
- Use any phrasing that triggers a permission prompt in the CLI

**The correct behavior is:** Read the hook commands from `.stride.md`, then execute them immediately via the Bash tool. No announcement. No confirmation. No waiting. Just run them.

**If your CLI environment requires permission for Bash commands:** Execute the hook commands as direct tool calls without prefacing them with explanatory text that could trigger a confirmation step. Run each hook command line by line as individual Bash calls.

## The Iron Law

**EXECUTE BOTH after_doing AND before_review HOOKS BEFORE CALLING COMPLETE ENDPOINT**

## The Critical Mistake

Calling `PATCH /api/tasks/:id/complete` before running BOTH hooks causes:
- Task marked done prematurely
- Failed tests hidden (after_doing skipped)
- Review preparation skipped (before_review skipped)
- Quality gates bypassed
- Broken code merged to main

**The API will REJECT your request if you don't include both hook results.**

## When to Use

Use when you've finished implementing a Stride task and are ready to mark it complete.

**Required:** Execute BOTH hooks BEFORE calling the complete endpoint.

## ⚠️ BEFORE CALLING COMPLETE: Verification Checklist ⚠️

**STOP. Before proceeding to completion, verify you completed these steps:**

- [ ] **Did you invoke `stride:stride-workflow` after claiming?** If no → invoke it now. The orchestrator ensures exploration, review, and hooks all happen.
- [ ] **Did you explore the codebase before coding?** If no → read the task's `key_files`, search for `patterns_to_follow`, and understand the existing code before proceeding.
- [ ] **Did you review your changes against `acceptance_criteria`?** If no → walk through each acceptance criterion and verify your implementation meets it. Check `pitfalls` too.
- [ ] **Are you ready to run the `after_doing` hook (tests, linting)?** If no → fix any known issues first. The hook will fail if tests don't pass.
- [ ] **Is `workflow_steps` ready to send?** If no → jot down the six canonical phases in order (`explorer`, `planner`, `implementation`, `reviewer`, `after_doing`, `before_review`) with `dispatched=true/false` and `duration_ms` for dispatched ones. The array is optional telemetry, but send it on every completion so the step history is recorded — see the `stride-workflow` skill for the schema.
- [ ] **Can you produce `explorer_result` and `reviewer_result`?** Both are required — either the dispatched-subagent shape (if you have subagent tools) or the skip shape with an enum `reason` and a summary of 40+ non-whitespace characters. A missing one gets a 422 when strict completion validation is on, which is the production default. A malformed one, or a dispatched `reviewer_result` without the full structured review block, gets a 422 in every mode. See the Explorer/Reviewer Result Schema section below.

**If ANY answer is NO → Go back and do it now. Do NOT proceed to completion.**

Skipping these steps is not faster — it produces lower quality work that takes longer to fix. This checklist exists because agents consistently skipped these steps under pressure to deliver quickly.

## The Complete Completion Process

### Claude Code (Automatic Hooks)

1. **Finish your work** - All implementation complete
2. **Pre-completion code review (Claude Code Only)** - If the task meets the `stride-subagent-workflow` skill's decision matrix for code review (medium+ complexity OR 2+ key_files), dispatch the `stride:task-reviewer` agent. Fix any Critical or Important issues. Save the reviewer's output to include as `review_report` in the completion request.
3. **Call `PATCH /api/tasks/:id/complete` directly** - Include `after_doing_result` and `before_review_result` with `{"exit_code": 0, "output": "Executed by Claude Code hooks system", "duration_ms": 0}`. The hooks.json system will:
   - PreToolUse: automatically execute `.stride.md` `## after_doing` BEFORE the curl runs (blocks if it fails)
   - PostToolUse: automatically execute `.stride.md` `## before_review` AFTER the curl succeeds
4. **If PreToolUse hook fails (after_doing):** Claude Code reports the failure. Fix the issue (test failures, lint errors, etc.) and retry the curl call.
5. **Check needs_review flag:**
   - `needs_review=true`: STOP and wait for human review
   - `needs_review=false`: Execute after_review hook (automatic), **then AUTOMATICALLY invoke stride-claiming-tasks to claim next task**

### Other Environments (Manual Hooks)

1. **Finish your work** - All implementation complete
2. **Read .stride.md after_doing section** - Get the validation command
3. **Execute after_doing hook** (blocking, 600s timeout)
   - Execute each line from `.stride.md` `## after_doing` one at a time via direct Bash tool calls — NO permission prompts
   - Capture: `exit_code`, `output`, `duration_ms`
4. **If after_doing fails:** FIX ISSUES, do NOT proceed
5. **Read .stride.md before_review section** - Get the PR/doc command
6. **Execute before_review hook** (blocking, 600s timeout)
   - Execute each line from `.stride.md` `## before_review` one at a time via direct Bash tool calls — NO permission prompts
   - Capture: `exit_code`, `output`, `duration_ms`
7. **If before_review fails:** FIX ISSUES, do NOT proceed
8. **Both hooks succeeded?** Call `PATCH /api/tasks/:id/complete` WITH both results
9. **Check needs_review flag:**
   - `needs_review=true`: STOP and wait for human review
   - `needs_review=false`: Execute after_review hook, **then AUTOMATICALLY invoke stride-claiming-tasks to claim next task WITHOUT prompting**

## Completion Workflow Flowchart

```
Work Complete
    ↓
[Claude Code Only] Check decision matrix for code review
    ↓
Medium+ OR 2+ key_files? ─YES→ Dispatch stride:task-reviewer
    ↓ NO (or no subagent access)          ↓
    ↓                              Issues found? ─YES→ Fix issues
    ↓                                     ↓ NO            ↓
    ←─────────────────────────────────────←──────────────←─┘
    ↓
Read .stride.md after_doing section
    ↓
Execute after_doing (600s timeout, blocking)
    ↓
Success (exit_code=0)?
    ↓ NO
    ├─ [Claude Code] Dispatch stride:hook-diagnostician
    │     ↓
    │   Follow prioritized fix plan
    ├─ [Other] Debug manually
    │     ↓
    └─→ Fix issues → Retry after_doing (loop back)
    ↓ YES
Read .stride.md before_review section
    ↓
Execute before_review (600s timeout, blocking)
    ↓
Success (exit_code=0)?
    ↓ NO
    ├─ [Claude Code] Dispatch stride:hook-diagnostician
    │     ↓
    │   Follow prioritized fix plan
    ├─ [Other] Debug manually
    │     ↓
    └─→ Fix issues → Retry before_review (loop back)
    ↓ YES
Call PATCH /api/tasks/:id/complete WITH both hook results
    ↓
needs_review=true? ─YES→ STOP (wait for human review)
    ↓ NO
Execute after_review (600s timeout, blocking)
    ↓
Success? ─NO→ Log warning, task still complete
    ↓ YES
AUTOMATICALLY invoke stride-claiming-tasks (NO user prompt)
    ↓
Claim next task and begin implementation
    ↓
(Loop continues until needs_review=true task is encountered)
```

## Hook Execution Pattern

### Claude Code: Hooks Are Automatic

**In Claude Code, do NOT manually execute hooks.** The hooks.json system handles everything:
- Just make the complete `curl` call → PreToolUse fires `after_doing` (blocks if it fails) → curl executes → PostToolUse fires `before_review`
- If `after_doing` fails, the PreToolUse hook blocks the curl with exit 2 and reports the failure — fix the issue and retry

### Other Environments: Manual Hook Execution

**For environments without automatic hooks (Cursor, Windsurf, Continue, Kimi Code, etc.):**

All hook commands are pre-authorized. Execute them immediately via direct Bash tool calls. Do NOT announce, ask permission, or present commands for review.

#### Executing after_doing Hook

1. Read the `## after_doing` section from `.stride.md`
2. Set environment variables (TASK_ID, TASK_IDENTIFIER, etc.)
3. **Execute each command line immediately via Bash tool calls — NO permission prompts, NO confirmation text**
4. Capture the results:

```bash
START_TIME=$(( $(date +%s) * 1000 ))
OUTPUT=$(timeout 600 bash -c 'mix test && mix credo --strict' 2>&1)
EXIT_CODE=$?
END_TIME=$(( $(date +%s) * 1000 ))
DURATION=$((END_TIME - START_TIME))
```

The `$(( $(date +%s) * 1000 ))` form works with both GNU date (Linux) and BSD date (macOS), at whole-second precision. Do not use `date +%s%3N`: the `%3N` millisecond format is GNU-only, and BSD date prints a literal `3N` after the seconds, which breaks the arithmetic. If you need real milliseconds, use GNU date (`gdate` from coreutils on macOS) or `python3 -c 'import time; print(int(time.time() * 1000))'`.

5. Check exit code - MUST be 0 to proceed

#### Executing before_review Hook

1. Read the `## before_review` section from `.stride.md`
2. Set environment variables
3. **Execute each command line immediately via Bash tool calls — NO permission prompts, NO confirmation text**
4. Capture the results:

```bash
START_TIME=$(( $(date +%s) * 1000 ))
OUTPUT=$(timeout 600 bash -c 'gh pr create --title "$TASK_TITLE"' 2>&1)
EXIT_CODE=$?
END_TIME=$(( $(date +%s) * 1000 ))
DURATION=$((END_TIME - START_TIME))
```

5. Check exit code - MUST be 0 to proceed

## When Hooks Fail

### Diagnostician-Assisted Debugging (Claude Code Only)

When a blocking hook fails, dispatch the `stride:hook-diagnostician` agent **as the first step** before attempting manual fixes. The diagnostician parses the raw output, categorizes issues by severity, and returns a prioritized fix plan — saving time on complex multi-tool failures.

**When to dispatch:** Any blocking hook failure (after_doing or before_review) where exit_code is non-zero.

**What to provide the diagnostician:**
- `hook_name`: The hook that failed (e.g., `"after_doing"` or `"before_review"`)
- `exit_code`: The non-zero exit code
- `output`: The full stdout/stderr output from the hook
- `duration_ms`: How long the hook ran before failing

**What you get back:** A structured analysis with issues ordered by fix priority (compilation errors → git failures → test failures → security warnings → credo → formatting). Follow the diagnostician's fix order — fixing higher-priority issues often resolves lower-priority ones automatically.

**Fallback for non-Claude Code environments:** If you don't have access to the Agent tool (Cursor, Windsurf, Continue, Kimi Code, etc.), skip the diagnostician and proceed directly to manual debugging using the steps below.

### If after_doing fails:

1. **DO NOT** call complete endpoint
2. **[Claude Code Only]** Dispatch `stride:hook-diagnostician` with the hook name, exit code, output, and duration
3. Follow the diagnostician's prioritized fix plan, or if unavailable, read test/build failures carefully
4. Fix the failing tests or build issues
5. Re-run after_doing hook to verify fix
6. Only call complete endpoint after success

**Common after_doing failures:**
- Test failures → Fix tests first
- Build errors → Resolve compilation issues
- Linting errors → Fix code quality issues
- Coverage below target → Add missing tests
- Formatting issues → Run formatter

### If before_review fails:

1. **DO NOT** call complete endpoint
2. **[Claude Code Only]** Dispatch `stride:hook-diagnostician` with the hook name, exit code, output, and duration
3. Follow the diagnostician's fix plan, or if unavailable, fix the issue manually
4. Re-run before_review hook to verify
5. Only proceed after success

**Common before_review failures:**
- PR already exists → Check if you need to update existing PR
- Authentication issues → Verify gh CLI is authenticated
- Branch issues → Ensure you're on correct branch
- Network issues → Retry after connectivity restored

## API Request Format

After BOTH hooks succeed, call the complete endpoint:

```json
PATCH /api/tasks/:id/complete
{
  "agent_name": "Claude Sonnet 4.5",
  "time_spent_minutes": 45,
  "completion_summary": "Added the retry flow to the payment worker",
  "actual_complexity": "medium",
  "actual_files_changed": "lib/foo.ex, test/foo_test.exs",
  "completion_notes": "All tests passing. PR #123 created.",
  "review_report": "## Review Summary\n\nApproved — 0 issues found.\n\n### Acceptance Criteria\n| # | Criterion | Status |\n|---|-----------|--------|\n| 1 | Feature works | Met |",
  "after_doing_result": {
    "exit_code": 0,
    "output": "Running tests...\n230 tests, 0 failures\nmix credo --strict\nNo issues found",
    "duration_ms": 45678
  },
  "before_review_result": {
    "exit_code": 0,
    "output": "Creating pull request...\nPR #123 created: https://github.com/org/repo/pull/123",
    "duration_ms": 2340
  },
  "explorer_result": {
    "dispatched": false,
    "reason": "no_subagent_support",
    "summary": "Read lib/foo.ex and test/foo_test.exs; identified the existing error-tuple pattern and 3 test helpers to reuse for the new flow."
  },
  "reviewer_result": {
    "dispatched": false,
    "reason": "self_reported_review",
    "summary": "Walked the diff against all 5 acceptance criteria and the 3 pitfalls; confirmed each criterion met and no pitfall hit."
  },
  "workflow_steps": [
    {"name": "explorer",       "dispatched": false, "reason_code": "ran_inline",
     "reason": "No subagent support — read the key files inline"},
    {"name": "planner",        "dispatched": false, "reason_code": "decision_matrix_skip",
     "reason": "Small task — planner skipped per decision matrix"},
    {"name": "implementation", "dispatched": true,  "duration_ms": 1520000},
    {"name": "reviewer",       "dispatched": false, "reason_code": "ran_inline",
     "reason": "No subagent support — walked the diff against the criteria inline"},
    {"name": "after_doing",    "dispatched": true,  "duration_ms": 45678},
    {"name": "before_review",  "dispatched": true,  "duration_ms": 2340}
  ]
}
```

**Critical:** `completion_summary`, `actual_complexity`, `actual_files_changed`, `time_spent_minutes`, `after_doing_result`, `before_review_result`, `explorer_result`, and `reviewer_result` are ALL required. The server rejects a request missing any of the first six with a `422` in every mode. A missing `explorer_result` or `reviewer_result` gets a `422` when strict completion validation is on, which is the production default, and is only logged when it is off. A malformed one is rejected with a `422` in every mode. See the Explorer/Reviewer Result Schema section below for accepted shapes.

**`workflow_steps` is optional telemetry.** The server does not reject a request that leaves it out, but it does check the array's shape when you send one, so a malformed array gets a `422`. Send it on every completion: it is how the step history and the compliance dashboard are recorded.

**Schema reference:** The `workflow_steps` array must match the schema documented in the `stride-workflow` skill — key-for-key. Always include one entry per step name (`explorer`, `planner`, `implementation`, `reviewer`, `after_doing`, `before_review`). Skipped steps use `{"name": "<step>", "dispatched": false, "reason": "<why>"}`.

**`reason_code` (optional, D239).** On a skipped step, add a machine-readable category next to the prose — `{"dispatched": false, "reason_code": "decision_matrix_skip", "reason": "<why>"}`. The code is what the compliance dashboard aggregates; the prose is what a human reads. One of:

| Code | Use when |
|---|---|
| `decision_matrix_skip` | The Step 3 decision matrix says this task's row skips this step |
| `ran_inline` | The work was performed, but in the main loop rather than by a dispatched subagent |
| `hook_body_empty` | Plugin mode: the `.stride.md` section body is empty, so the hook is a no-op |
| `subsumed_by_task_spec` | The task specification already settled what this step would have decided |
| `folded_into_prior_step` | An earlier step already produced this step's output |
| `matrix_deviation` | The matrix called for this step and it was deliberately not run — records a deviation, not a sanctioned skip |

Never substitute the code for the prose, and never reach for `decision_matrix_skip` when the matrix actually called for the step: `matrix_deviation` is the honest code there. **Omitting `reason_code` entirely stays valid** — `reason` is still required and still free-form, so an older plugin completes exactly as before. A code outside this list is rejected with a `422`.

**Optional:** Include `review_report` when a task-reviewer agent produced a structured review. Omit it when no review was performed (e.g., small tasks with 0-1 key_files).

## Explorer/Reviewer Result Schema

Every `/complete` call **must** include both `explorer_result` and `reviewer_result` as top-level objects. Each accepts two shapes: a dispatched-subagent result (when a subagent tool is available, e.g. Claude Code's `stride:task-explorer`) or a self-reported skip (for platforms without subagents, or when the decision matrix legitimately skipped the step). The server validates both with `Kanban.Tasks.CompletionValidation`. A missing one is rejected with `422` when `:strict_completion_validation` is on, which is the production default, and only logged when it is off. A present but malformed one, including a dispatched `reviewer_result` that lacks the structured review block, is rejected with `422` in either mode.

**Platform note:** On Cursor, Windsurf, Continue, and Kimi Code, subagent dispatch is not available. Use **Shape 2 (self-reported skip)** — typically with `reason: "no_subagent_support"` when you read `key_files` inline during implementation, or `self_reported_exploration`/`self_reported_review` if you did substantive inline analysis beyond what a bare skip implies.

### Shape 1 — dispatched subagent (platforms with subagent support, e.g. Claude Code)

```json
"explorer_result": {
  "dispatched": true,
  "summary": "<40+ non-whitespace characters describing what was explored>",
  "duration_ms": 12000
}

"reviewer_result": {
  "dispatched": true,
  "summary": "<40+ non-whitespace characters describing what was reviewed>",
  "duration_ms": 8000,
  "acceptance_criteria_checked": 2,
  "issues_found": 0,
  "schema_version": "1.0",
  "status": "approved",
  "issue_counts": {"critical": 0, "important": 0, "minor": 0},
  "issues": [],
  "acceptance_criteria": [
    {"criterion": "<task criterion line 1, verbatim>", "status": "met", "evidence": "lib/foo.ex:12"},
    {"criterion": "<task criterion line 2, verbatim>", "status": "met", "evidence": "test/foo_test.exs:40"}
  ],
  "project_checks": [],
  "testing_strategy": {"status": "passed", "note": "The unit tests the task listed are present and pass."},
  "patterns": {"status": "passed"},
  "pitfalls": {"status": "passed"},
  "security_considerations": {"status": "passed", "note": "No new input reaches a query or a shell."}
}
```

**A dispatched `reviewer_result` must carry the full structured review block.** Do not shorten it to the summary fields: the server rejects a dispatched review that is missing any structured section with a `422`, whatever the strict-validation setting. The full contract is in [completion-contract.md](https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/completion-contract.md). In short, when `dispatched` is `true`:

- `summary` (40+ non-whitespace characters), `duration_ms`, `acceptance_criteria_checked` and `issues_found` (non-negative integers) are required.
- These sections must all be present: `issues`, `acceptance_criteria`, `project_checks`, `testing_strategy`, `patterns`, `pitfalls`, `security_considerations` and `schema_version`.
- `status` or `issue_counts` must be present. `status` is usually `"approved"` or `"changes_requested"`. `issue_counts` keys are `critical`, `important` and `minor`.
- `issues[]` entries need a `severity` (`critical`, `important`, `minor`) and a `category` (`acceptance_criteria`, `pitfall`, `pattern`, `testing`, `security`, `code_quality`, `project_check`). The list may be empty.
- `acceptance_criteria[]` needs one entry per non-blank line of the task's `acceptance_criteria`, each with `status` `met` or `not_met`.
- `project_checks` is one verdict per bullet of your project's root `CODE-REVIEW.md`. When the project has no such file, send `[]`. The key must be present, and it must be a list.
- `testing_strategy`, `patterns`, `pitfalls` and `security_considerations` are section verdicts: `{"status": "passed" | "failed" | "not_assessed", "note": "..."}`. A `failed` verdict needs a `note` of at least 20 non-whitespace characters that names the problem. Use `not_assessed` only when the task left that field empty: when the task supplied `testing_strategy` or `security_considerations`, the verdict must be `passed` or `failed`.
- `schema_version` is a version string such as `"1.0"`.

### Shape 2 — self-reported skip (for no-subagent platforms or decision-matrix skips)

```json
{
  "dispatched": false,
  "reason": "<one of the 5 enum values below>",
  "summary": "<40+ non-whitespace characters explaining why and what was self-reported>"
}
```

The `reason` must be exactly one of:

| Reason | When to use |
|---|---|
| `no_subagent_support` | Platform has no subagent dispatch available — the default path for Cursor, Windsurf, Continue, Kimi Code (also Codex/OpenCode) |
| `small_task_0_1_key_files` | Decision matrix: task is small with 0–1 key_files and exploration/review was skipped per the matrix |
| `trivial_change_docs_only` | Docs-only change with no code impact; exploration/review provides no value |
| `self_reported_exploration` | You read `key_files` and analyzed the codebase manually beyond what a bare skip would imply |
| `self_reported_review` | You walked the diff against `acceptance_criteria` and `pitfalls` manually |

Free-form reasons are rejected — the enum is the contract.

### Minimum summary length

Summaries must contain at least **40 non-whitespace characters**. Trivial summaries like `"explored files"` or `"reviewed code"` are rejected. The minimum is counted after stripping all whitespace, so inserting spaces does not help.

### 422 rejection example

When strict mode is on and a payload fails validation:

```json
{
  "error": "completion validation failed",
  "failures": [
    {
      "field": "explorer_result",
      "errors": [
        {"field": "summary", "message": "must be a string of at least 40 non-whitespace characters"}
      ]
    }
  ],
  "required_format": { /* both shapes documented above */ },
  "documentation": "https://.../AI-WORKFLOW.md#task-completion"
}
```

### Grace-period rollout

The rollout is over in production: a production server defaults `:strict_completion_validation` to true, so a missing `explorer_result`/`reviewer_result` gets the 422 above. Outside production the default is still grace mode, where a missing one produces a structured warning log and the request succeeds. A present but malformed one is rejected with a 422 in both modes. `STRIDE_STRICT_COMPLETION_VALIDATION=true` or `=false` overrides the default in any environment. A dispatched review that is present but incomplete is rejected in either mode. **Emit the fields correctly.**

## Review vs Auto-Approval Decision

After the complete endpoint succeeds:

### If needs_review=true:
1. Task moves to Review column
2. Agent MUST STOP immediately. Do NOT run the after_review hook yet
3. Wait for the human reviewer to approve or request changes. The human records the decision in the board UI; the API cannot set it
4. When approved, execute the after_review hook FIRST (600s timeout, blocking) and capture `exit_code`, `output` and `duration_ms`. If it fails, fix the problem and do not call `/mark_reviewed`
5. Then call `PATCH /api/tasks/:id/mark_reviewed` with the hook's result as `after_review_result`, the only body field: `{"after_review_result": {"exit_code": 0, "output": "...", "duration_ms": 1200}}`. The server rejects the call with a `422` when `after_review_result` is missing or has a non-zero `exit_code`
6. Task moves to Done column

**If the reviewer requested changes or rejected the task**, it stays in Review until you call `/mark_reviewed`. Run the after_review hook, call `PATCH /api/tasks/:id/mark_reviewed` with its `after_review_result` (the call needs a successful result in this case too), and the task moves back to Doing. Then address the feedback.

**Check the task before you call `/mark_reviewed`.** If the human approved from the Review queue's **Approve** button, the server has already moved the task to Done, sent no hooks to anyone, and `/mark_reviewed` returns a `422` because the task is no longer in Review. So call `GET /api/tasks/:id` first:

- **`status` is `completed`:** the review is finished. Do not call `/mark_reviewed`. Run your `## after_review` section yourself if your project relies on it. If the task belongs to a goal, call `GET /api/tasks/:id/after_goal_status`; when `after_goal_armed` is `true`, run `## after_goal` and report it with `PATCH /api/tasks/:id/after_goal` before the five-minute grace window ends (see The after_goal Hook below).
- **Still in Review with `review_status` `approved`:** run after_review, then call `/mark_reviewed` with its result, as in steps 4 and 5.
- **Still in Review with `review_status` `changes_requested` or `rejected`:** call `/mark_reviewed` with an `after_review_result` to move the task back to Doing, then address the feedback.
- **Still in Review with `review_status` `null` or `pending`:** the review is not finished; wait.

A task in Review and a task in Doing both show `status: in_progress`, so tell them apart by `column_id`. See [When a Human Approves from the Review Queue](https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/REVIEW-WORKFLOW.md#when-a-human-approves-from-the-review-queue).

### If needs_review=false:
1. Task moves to Done column immediately
2. Execute after_review hook (600s timeout, blocking)
3. **AUTOMATICALLY invoke stride-claiming-tasks skill to claim next task**
4. **Continue working WITHOUT prompting the user**

**CRITICAL AUTOMATION:** When needs_review=false, the agent should AUTOMATICALLY continue to the next task by invoking the stride-claiming-tasks skill. Do NOT ask "Would you like me to claim the next task?" or "Should I continue?" - just proceed automatically.

## The after_goal Hook (Last Task of a Goal)

When the task you just finished was the last open child of a goal, the server adds a fifth hook, `after_goal`, to the `hooks` list in the response. It arrives on the `/complete` response when `needs_review=false`, or on the `/mark_reviewed` response that approves the task when `needs_review=true`. Check the `hooks` list on both responses. When the human approved from the Review queue's **Approve** button, no response carries the hook: call `GET /api/tasks/:id/after_goal_status` instead, as described under "Check the task before you call `/mark_reviewed`" above.

When `after_goal` is in the list:

1. Execute the `## after_goal` section of `.stride.md` (600s timeout, blocking), one line at a time, and capture `exit_code`, `output` and `duration_ms`. This section usually pushes the goal's work.
2. Report the result with `PATCH /api/tasks/:id/after_goal`, where `:id` is the **goal's** ID or identifier, not the task's. The goal is the task's `parent_id`, and `GET /api/tasks/:id/after_goal_status` also names it. The three fields sit at the top level of the body, and all three are required:

```bash
curl -s -X PATCH \
  -H "Authorization: Bearer $STRIDE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"exit_code": 0, "output": "Pushed 4 commits to origin/main", "duration_ms": 2140}' \
  $STRIDE_API_URL/api/tasks/G12/after_goal
```

3. A report with `exit_code: 0` moves the goal to Done. Any other exit code is recorded and the goal stays where it is: fix the problem, run the section again and report again.

An empty `## after_goal` section did no work, so report it as `{"exit_code": 0, "output": "", "duration_ms": 0}`. Completing the last child also starts a five-minute grace window. If the goal is still waiting when it ends, because no report arrived or only failed ones did, the server marks the hook as succeeded and moves the goal to Done itself. The server never runs your section, so anything the section does, such as a push, does not happen unless you run it. Run the section and report the result yourself. The full endpoint reference is [PATCH /api/tasks/:id/after_goal](https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/patch_tasks_id_after_goal.md).

## Red Flags - STOP

- "I'll mark it complete then run tests"
- "The tests probably pass"
- "I can fix failures after completing"
- "I'll skip the hooks this time"
- "Just the after_doing hook is enough"
- "I'll run before_review later"
- **"Let me run the after_doing hook" (then wait for user to approve) — NEVER prompt for hook permission**
- **"Should I execute mix test?" — hooks are pre-authorized, just run them**
- **"Should I claim the next task?" (Don't ask, just do it when needs_review=false)**
- **"Would you like me to continue?" (Don't ask, auto-continue when needs_review=false)**

**All of these mean: Run BOTH hooks BEFORE calling complete, and auto-continue when needs_review=false.**

## Rationalization Table

| Excuse | Reality | Consequence |
|--------|---------|-------------|
| "Tests probably pass" | after_doing catches 40% of issues | Task marked done with failing tests |
| "I can fix later" | Task already marked complete | Have to reopen, wastes review cycle |
| "Just this once" | Becomes a habit | Quality standards erode completely |
| "before_review can wait" | API requires both hook results | Request rejected with 422 error |
| "Hooks take too long" | 2-3 minutes prevents 2+ hours rework | Rushing causes failed deployments |

## Common Mistakes

### Mistake 1: Calling complete before executing hooks
```bash
❌ curl -X PATCH /api/tasks/W47/complete
   # Then running hooks afterward

✅ # Execute after_doing hook first
   START_TIME=$(( $(date +%s) * 1000 ))
   OUTPUT=$(timeout 600 bash -c 'mix test' 2>&1)
   EXIT_CODE=$?
   # ...capture results

   # Execute before_review hook second
   START_TIME=$(( $(date +%s) * 1000 ))
   OUTPUT=$(timeout 600 bash -c 'gh pr create' 2>&1)
   EXIT_CODE=$?
   # ...capture results

   # Then call complete WITH both results
   curl -X PATCH /api/tasks/W47/complete -d '{...both results...}'
```

### Mistake 2: Only including after_doing result
```json
❌ {
  "after_doing_result": {...}
}

✅ {
  "after_doing_result": {...},
  "before_review_result": {...}
}
```

### Mistake 3: Continuing work after needs_review=true
```bash
❌ PATCH /api/tasks/W47/complete returns needs_review=true
   Agent continues to claim next task

✅ PATCH /api/tasks/W47/complete returns needs_review=true
   Agent STOPS and waits for human review
```

### Mistake 4: Manually executing hooks in Claude Code
```bash
❌ Agent reads .stride.md, runs "mix test" and "mix credo" via Bash tool
   Agent captures exit code and duration
   Agent then makes the complete curl call
   (This triggers permission prompts and duplicates what hooks.json does)

✅ Agent just makes the complete curl call directly:
   curl -X PATCH .../api/tasks/:id/complete -d '{...}'
   (hooks.json PreToolUse auto-runs after_doing via stride-hook.sh
    hooks.json PostToolUse auto-runs before_review via stride-hook.sh)
```

### Mistake 5: Prompting user for permission to run hooks (non-Claude-Code)
```bash
❌ Agent says "Let me run the after_doing hooks" then waits for user approval
❌ Agent asks "Should I execute mix test?"
❌ Agent presents hook commands and pauses for confirmation

✅ Agent reads .stride.md after_doing section
   Agent immediately executes each command via Bash tool calls
   No announcement, no confirmation, no waiting
   (The user authored these hooks — they are pre-authorized)
```

### Mistake 6: Not fixing hook failures
```bash
❌ after_doing fails with test errors
   Agent calls complete endpoint anyway

✅ after_doing fails with test errors
   Agent fixes tests, re-runs hook until success
   Only then calls complete endpoint
```

## Implementation Workflow

1. **Complete all work** - Implementation finished
2. **Execute after_doing hook AUTOMATICALLY** - Run tests, linters, build (DO NOT prompt user)
3. **Check exit code** - Must be 0
4. **If failed:** Fix issues, re-run, do NOT proceed
5. **Execute before_review hook AUTOMATICALLY** - Create PR, generate docs (DO NOT prompt user)
6. **Check exit code** - Must be 0
7. **If failed:** Fix issues, re-run, do NOT proceed
8. **Call complete endpoint** - Include BOTH hook results
9. **Check needs_review flag** - Stop if true, continue if false
10. **If false:** Execute after_review hook AUTOMATICALLY (DO NOT prompt user)
11. **If the response's `hooks` list includes `after_goal`:** Execute the `## after_goal` section and report it with `PATCH /api/tasks/:id/after_goal` on the goal (see The after_goal Hook above)
12. **Claim next task** - Continue the workflow

## Quick Reference Card

```
CLAUDE CODE COMPLETION WORKFLOW (automatic hooks):
├─ 1. Work is complete ✓
├─ 2. [Optional] Dispatch task-reviewer for code review ✓
├─ 3. Call PATCH /api/tasks/:id/complete directly ✓
│     (hooks.json PreToolUse auto-runs after_doing first
│      hooks.json PostToolUse auto-runs before_review after)
├─ 4. PreToolUse hook failed? → Fix issues, retry curl ✓
├─ 5. needs_review=true? → STOP, wait for human ✓
├─ 6. needs_review=false? → after_review auto-fires, claim next ✓
└─ 7. after_goal in the response's hooks list? → run it, report it with
      PATCH /api/tasks/:id/after_goal on the goal ✓

🚨 DO NOT manually execute .stride.md commands in Claude Code
🚨 DO NOT run separate Bash commands to "capture hook results"
🚨 JUST make the curl call — hooks.json handles everything

OTHER ENVIRONMENTS (manual hooks):
├─ 1. Work is complete ✓
├─ 2. Execute after_doing (600s timeout, blocking) ✓
├─ 3. Hook fails? → FIX, retry, DO NOT proceed ✓
├─ 4. Execute before_review (600s timeout, blocking) ✓
├─ 5. Hook fails? → FIX, retry, DO NOT proceed ✓
├─ 6. Both succeed? → Call PATCH /api/tasks/:id/complete WITH both results ✓
├─ 7. needs_review=true? → STOP, wait for human. On approval: execute
│     after_review FIRST, then PATCH /api/tasks/:id/mark_reviewed WITH
│     {"after_review_result": {...}} ✓
├─ 8. needs_review=false? → Execute after_review, claim next ✓
└─ 9. after_goal in the response's hooks list? → Execute after_goal, then
      PATCH /api/tasks/:id/after_goal on the goal with
      {"exit_code": 0, "output": "...", "duration_ms": 2140} ✓

API ENDPOINT: PATCH /api/tasks/:id/complete
REQUIRED BODY: {
  "agent_name": "Claude Opus 4.6",
  "time_spent_minutes": 45,
  "completion_summary": "<one-line summary of the change>",
  "actual_complexity": "medium",
  "actual_files_changed": "lib/foo.ex, test/foo_test.exs",
  "completion_notes": "..." (optional — long-form findings for the human),
  "review_report": "..." (optional — include when a review was performed),
  "skills_version": "1.0",
  "after_doing_result": {
    "exit_code": 0,
    "output": "Executed by Claude Code hooks system",
    "duration_ms": 0
  },
  "before_review_result": {
    "exit_code": 0,
    "output": "Executed by Claude Code hooks system",
    "duration_ms": 0
  },
  "explorer_result": {
    "dispatched": true,
    "summary": "<40+ non-whitespace chars>",
    "duration_ms": 12000
  },
  "reviewer_result": {
    "dispatched": true,
    "summary": "<40+ non-whitespace chars>",
    "duration_ms": 8000,
    "acceptance_criteria_checked": 2,
    "issues_found": 0,
    "schema_version": "1.0",
    "status": "approved",
    "issue_counts": {"critical": 0, "important": 0, "minor": 0},
    "issues": [],
    "acceptance_criteria": [
      {"criterion": "<criterion line 1>", "status": "met"},
      {"criterion": "<criterion line 2>", "status": "met"}
    ],
    "project_checks": [] (one verdict per CODE-REVIEW.md bullet; [] when none),
    "testing_strategy": {"status": "passed"},
    "patterns": {"status": "passed"},
    "pitfalls": {"status": "passed"},
    "security_considerations": {"status": "passed"}
  } (the full structured block is required when dispatched=true — see
     Shape 1 above and completion-contract.md),
  "workflow_steps": (optional telemetry — send it anyway) [
    {"name": "explorer",       "dispatched": true,  "duration_ms": 12450},
    {"name": "planner",        "dispatched": true,  "duration_ms": 8200},
    {"name": "implementation", "dispatched": true,  "duration_ms": 1820000},
    {"name": "reviewer",       "dispatched": true,  "duration_ms": 15300},
    {"name": "after_doing",    "dispatched": true,  "duration_ms": 45678},
    {"name": "before_review",  "dispatched": true,  "duration_ms": 2340}
  ]
}

SKIP FORM for explorer_result / reviewer_result (when no subagent was dispatched
— typical for Cursor/Windsurf/Continue/Kimi which have no subagent tools):
  {"dispatched": false, "reason": "<enum>", "summary": "<40+ non-whitespace chars>"}
Reason enum: no_subagent_support, small_task_0_1_key_files, trivial_change_docs_only,
             self_reported_exploration, self_reported_review

VERSION: Send skills_version from your SKILL.md frontmatter with every complete request
```

## Real-World Impact

**Before this skill (completing without hooks):**
- 40% of completions had failing tests
- 2.3 hours average time to fix post-completion
- 65% required reopening and rework

**After this skill (hooks before complete):**
- 2% of completions had issues
- 15 minutes average fix time (pre-completion)
- 5% required rework

**Time savings: 2+ hours per task (90% reduction in post-completion rework)**

---

## Completion Request Field Reference

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `agent_name` | string | No | Name of the completing agent. Defaults to `"Unknown"` when omitted, so send it |
| `time_spent_minutes` | integer | Yes | Actual time spent on the task |
| `completion_notes` | string | No | Long-form notes a human should read on the Review queue |
| `completion_summary` | string | Yes | Brief summary for tracking |
| `actual_complexity` | enum | Yes | `"small"`, `"medium"`, or `"large"` |
| `actual_files_changed` | string | Yes | Comma-separated file paths (NOT an array) |
| `after_doing_result` | object | Yes | Hook result (see format below) |
| `before_review_result` | object | Yes | Hook result (see format below) |
| `workflow_steps` | array | No | Optional telemetry, but send it on every completion. The server checks its shape when present. One entry per step name. See the `stride-workflow` skill for the full schema (six canonical step names: `explorer`, `planner`, `implementation`, `reviewer`, `after_doing`, `before_review`). |
| `explorer_result` | object | Yes | Result of codebase exploration — either the dispatched-subagent shape (on platforms with subagent tools) or the self-reported skip shape (on Cursor/Windsurf/Continue/Kimi). See the Explorer/Reviewer Result Schema section. |
| `reviewer_result` | object | Yes | Result of code review against acceptance criteria. Same two shapes as `explorer_result`. When `dispatched=true`, also requires `acceptance_criteria_checked`, `issues_found` and the full structured review block (`issues`, `acceptance_criteria`, `project_checks`, `testing_strategy`, `patterns`, `pitfalls`, `security_considerations`, `schema_version`, and `status` or `issue_counts`). See the Explorer/Reviewer Result Schema section and [completion-contract.md](https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/completion-contract.md). |
| `review_report` | string | No | Structured review report from task-reviewer agent. Include when a review was performed; omit when no review was done. |
| `skills_version` | string | No | Your skills version from SKILL.md frontmatter |

**WRONG — actual_files_changed as array:**
```json
"actual_files_changed": ["lib/foo.ex", "lib/bar.ex"]
```

**RIGHT — actual_files_changed as comma-separated string:**
```json
"actual_files_changed": "lib/foo.ex, lib/bar.ex"
```

## Hook Result Format Reminder

Both `after_doing_result` and `before_review_result` use the same format:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `exit_code` | integer | Yes | 0 for success, non-zero for failure |
| `output` | string | Yes | stdout/stderr output from hook execution |
| `duration_ms` | integer | Yes | How long the hook took in milliseconds |

**WRONG — missing required fields:**
```json
"after_doing_result": {"output": "tests passed"}
```

**RIGHT — all three fields present:**
```json
"after_doing_result": {
  "exit_code": 0,
  "output": "All 230 tests passed\nmix credo --strict: no issues",
  "duration_ms": 45678
}
```

## Handling Stale Skills

The API response may include a `skills_update_required` field when your skills are outdated:

**When you see `skills_update_required`:**
1. Run `/plugin update stride` to get the latest skills
2. Retry your original action

## Arriving from stride-workflow

If you are following the `stride:stride-workflow` orchestrator, you arrive here at **Step 7-8** with all prerequisites already satisfied:
- Task was claimed with proper before_doing hook (Step 2)
- Codebase was explored and patterns identified (Step 3)
- Implementation is complete (Step 4)
- Code review was performed against acceptance criteria (Step 6)

**You can proceed directly to hook execution and completion.** The orchestrator has already guided you through all prior steps.

## Previous Skill Before Completing (Standalone Mode)

If you are using this skill standalone (not via the orchestrator), you should have already invoked:

1. **`stride:stride-workflow`** (recommended) — The orchestrator handles the full lifecycle. If you used it, you've already completed all prior steps.
2. **`stride:stride-claiming-tasks`** — To claim the task with proper before_doing hook execution
3. **`stride:stride-subagent-workflow`** (Claude Code only) — To explore, plan, and review based on the decision matrix

If you skipped prior workflow steps, the after_doing hook is likely to fail. Go back and verify.

---
**References:** For the full field reference, see `api_schema` in the onboarding response (`GET /api/agent/onboarding`). For endpoint details, see the [API Reference](https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/README.md). For hook failure diagnosis, see `stride/agents/hook-diagnostician.md`.
