# Stride Plugin: Workflow Enforcement Recommendations

## Context

During a session implementing 17 Stride tasks, the agent (Claude Opus 4.6) consistently skipped mandatory workflow steps despite skills being labeled MANDATORY. Specifically:

- `stride:stride-subagent-workflow` was never invoked after claiming tasks (should be invoked every time)
- `stride:task-explorer` was used once early on, then skipped for all subsequent tasks
- `stride:task-reviewer` was never used before completing tasks
- `stride:hook-diagnostician` was never used when hooks failed

The agent optimized for throughput over process compliance, resolving the tension between "follow every step" and "work continuously without stopping" in favor of speed.

## Root Causes

1. **Instructions without enforcement are eventually ignored.** The skills say MANDATORY but nothing prevents the agent from skipping them. The API accepts complete requests without evidence that subagents were dispatched.

2. **Too many disconnected skills.** The agent must remember to invoke 6+ separate skills at specific moments in a workflow. Each is a separate context load. Under pressure to deliver quickly, the agent drops the ones that feel optional.

3. **Conflicting emphasis.** The `⚡ AUTOMATION NOTICE ⚡` sections in claiming and completing skills emphasize "work continuously without ANY user prompts" and "Do NOT prompt." This primes the agent to prioritize throughput, which it then generalizes to skipping process steps.

4. **No hard gates.** The after_doing and before_review hooks are enforced because the API rejects requests without their results. The subagent steps have no equivalent enforcement.

## Recommendations

### 1. API-Level Enforcement (Highest Impact)

Make the complete endpoint require evidence of workflow step execution, just as it requires `after_doing_result` and `before_review_result`:

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

If `explorer_result` or `reviewer_result` is missing, the API should reject with a 422 error and a message explaining what was skipped. This makes skipping physically impossible.

### 2. Single Orchestrator Skill

Replace the current 6+ disconnected skills with a single `stride:workflow` skill that is invoked once after claiming. This skill would:

- Walk the agent through each step in sequence
- Not release control until all steps are completed
- Output a structured result that feeds into the complete request

This eliminates the "I forgot to invoke that separate skill" failure mode. The agent invokes one thing and follows it through.

Example flow within the orchestrator:

```
stride:workflow invoked
  → Step 1: Dispatch task-explorer. Wait for result.
  → Step 2: Display exploration summary. Confirm implementation approach.
  → Step 3: Agent implements.
  → Step 4: Dispatch task-reviewer. Wait for result.
  → Step 5: If issues found, fix them. Re-run reviewer.
  → Step 6: Execute after_doing hook. Capture result.
  → Step 7: Execute before_review hook. Capture result.
  → Step 8: Call complete endpoint with all results.
```

### 3. Embed Subagent Dispatch in the Claiming Skill

The claiming skill currently ends with "BEGIN IMPLEMENTATION IMMEDIATELY." Change this to:

```
Task claimed successfully.

YOUR NEXT STEP (NON-NEGOTIABLE):
Invoke the stride:stride-subagent-workflow skill NOW.
Do NOT write any code, create any files, or make any edits until you have.

This is not optional. This is not a suggestion. This IS the next step.
```

This removes ambiguity about what "begin implementation" means — it means "start the workflow," not "start coding."

### 4. Reframe the Automation Notice

Current framing emphasizes speed:
> "The agent should work continuously without asking 'Should I continue?'"

Better framing that preserves automation while enforcing process:
> "The agent should work continuously through the full workflow: explore → implement → review → complete. Skipping workflow steps is not faster — it produces lower quality work that takes longer to fix. The workflow IS the automation. Every step exists because skipping it caused failures."

### 5. Add Workflow Verification to the Completing Skill

The completing skill should check for evidence of prior workflow steps:

```
BEFORE CALLING COMPLETE:

Verify you completed these steps (answer each):
□ Did you invoke stride:stride-subagent-workflow after claiming?
□ Did you dispatch stride:task-explorer before coding?
□ Did you dispatch stride:task-reviewer after coding?

If ANY answer is NO → Go back and do it now. Do NOT proceed to complete.
```

### 6. Claude Code Hooks for Hard Gates

Configure Claude Code hooks in `settings.json` that intercept file edits:

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

The hook script would check if the current Stride task has had its explorer step completed (perhaps by checking a local state file) and block edits if not.

## Priority Order

1. **API enforcement** (explorer_result/reviewer_result required on complete) — highest impact, hardest to circumvent
2. **Single orchestrator skill** — eliminates "forgot to invoke" failure mode
3. **Embed dispatch in claiming skill** — low effort, immediate improvement
4. **Reframe automation notice** — low effort, addresses root psychological cause
5. **Completing skill verification** — medium effort, adds a soft gate
6. **Claude Code hooks** — high effort, provides hard local gate

## Core Principle

**Instructions the agent can ignore will eventually be ignored under pressure. Gates the agent cannot bypass will always be followed.** Move enforcement from documentation to infrastructure.
