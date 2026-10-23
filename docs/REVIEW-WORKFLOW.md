# Review Workflow for AI Agents

This guide explains how the review workflow operates in Stride and when tasks require human review.

## Overview

Stride provides flexible task review through the `needs_review` field. Tasks can either:
- **Auto-complete** (`needs_review: false`) - Move directly from Doing → Done
- **Require review** (`needs_review: true`) - Move through Doing → Review → Done

This allows humans to focus review effort on high-risk changes while agents autonomously complete low-risk tasks.

## The needs_review Field

### Field Details

- **Type**: Boolean
- **Default**: `false` (no review required)
- **Set by**: Task creator when creating the task
- **Available to agents**: Via `TASK_NEEDS_REVIEW` environment variable in hooks

### Why Default to False?

Most tasks in a typical workflow are low-risk:
- Documentation updates
- Test additions
- Minor bug fixes
- Code formatting
- Non-critical refactoring

Defaulting to `false` reduces friction for autonomous agent operation and focuses human attention where it's most valuable.

## Workflow Behavior

### When needs_review = false (Auto-Complete)

**Workflow:**
1. Execute `before_doing` hook (blocking), then claim the task from the Ready column
2. Agent completes work
3. Execute `after_doing` hook (blocking) - quality checks MUST pass
4. Execute `before_review` hook (blocking) - still runs for automation
5. Agent calls `/api/tasks/:id/complete` with both hook results
6. **Task moves directly to Done** - skips Review column
7. Execute `after_review` hook from the response's `hooks` list - still runs for automation; its result is not reported to the server
8. If the `hooks` list also carries `after_goal`, this task finished its goal: run it and report it (see [Which Response Carries Each Hook](#which-response-carries-each-hook))
9. **Agent IMMEDIATELY claims next task** - continue working

**Key Point**: Review hooks still execute even when `needs_review = false`. This allows automated quality checks, PR creation, and other automation while bypassing human review.

**Use Cases:**
- Documentation updates (README, inline comments)
- Automated dependency updates (minor versions)
- Minor bug fixes in non-critical code
- Test additions
- Code formatting/linting changes
- Refactoring with no behavioral changes
- Configuration updates (non-production)

**Example:**
```bash
# Task: "Update API documentation"
# needs_review: false

# After completion:
# - after_doing hook runs tests ✓
# - before_review hook creates PR ✓
# - after_review hook auto-merges PR ✓
# - Task moves to Done
# - Agent claims next task immediately
```

### When needs_review = true (Human Review Required)

**Workflow:**
1. Execute `before_doing` hook (blocking), then claim the task from the Ready column
2. Agent completes work
3. Execute `after_doing` hook (blocking) - quality checks MUST pass
4. Execute `before_review` hook (blocking) - create PR, notify reviewers
5. Agent calls `/api/tasks/:id/complete` with both hook results
6. **Task moves to Review column**
7. **Task waits for human review** - agent STOPS and does not claim next task
8. Human records `review_status` (approved/changes_requested/rejected) in the board UI: the Review queue's **Approve** or **Request changes** button, or the task's Review Status field
9. If approved: Execute `after_review` hook (blocking) - merge PR, deploy
10. If approved: Agent calls `/api/tasks/:id/mark_reviewed` with `after_review_result`
11. Task moves to Done. If the `mark_reviewed` response's `hooks` list carries `after_goal`, run it and report it
12. If changes_requested or rejected: Agent does **not** run `after_review`. It calls `/api/tasks/:id/mark_reviewed` with a [placeholder `after_review_result`](#the-placeholder-after_review_result), and the task returns to Doing for agent to address feedback

When the human approves with the Review queue's **Approve** button, the server finishes steps 10 and 11 itself and the task is already in Done; see [When a Human Approves from the Review Queue](#when-a-human-approves-from-the-review-queue).

**Use Cases:**
- Security-related changes (authentication, authorization, encryption)
- Database schema migrations
- API contract changes (breaking changes to public APIs)
- Production configuration changes
- Financial/payment processing logic
- Data privacy/compliance changes

**Example:**
```bash
# Task: "Implement OAuth2 authentication"
# needs_review: true

# After completion:
# - after_doing hook runs security scans ✓
# - before_review hook creates PR and notifies reviewers ✓
# - Task moves to Review
# - AGENT STOPS - does not claim next task
# - Human reviews security implementation
# - Human approves (review_status = "approved")
# - after_review hook merges PR ✓
# - Agent calls mark_reviewed with after_review_result
# - Task moves to Done
```

### Review Statuses

A task in the Review column carries a `review_status`, which a **human reviewer** records in the board UI. Agents never set it — `PATCH /api/tasks/:id` refuses the field — they only read it, through [GET /api/tasks/:id](api/get_tasks_id.md), and then call [PATCH /api/tasks/:id/mark_reviewed](api/patch_tasks_id_mark_reviewed.md) to act on it.

| `review_status` | What `mark_reviewed` does |
|-----------------|---------------------------|
| not set (`null`) | Rejects the call with `422` — no review has been recorded yet; wait for the human reviewer |
| `pending` | Rejects the call with `422` — the review is not finished; wait for a decision |
| `approved` | Moves the task to Done and marks it `completed` |
| `changes_requested` | Moves the task back to Doing (status `in_progress`, still assigned to you) to address the feedback |
| `rejected` | Moves the task back to Doing (status `in_progress`, still assigned to you), exactly like `changes_requested` |

`mark_reviewed` has no `status` parameter. Its only body field is `after_review_result`, which it checks before it looks at the review decision, so a call that sends the task back to Doing needs a successful `after_review_result` too. **That result must not come from running `## after_review`**: the section typically merges or deploys, and the human did not accept the work. Send the placeholder below instead. A task that is not in the Review column is refused with `422`. An approval returns a `hooks` list with `after_review`, plus `after_goal` when the task was the last open child of a goal. A call that sends the task back to Doing returns no `hooks` list. See [PATCH /api/tasks/:id/mark_reviewed](api/patch_tasks_id_mark_reviewed.md) for the request and the error bodies.

### The Placeholder after_review_result

On `changes_requested` or `rejected`, **do not run `## after_review`**. The hook environment carries no review status (only `TASK_NEEDS_REVIEW`), so the section cannot tell a rejection from an approval and would merge or deploy the rejected work. Call `mark_reviewed` with this body instead:

```json
{
  "after_review_result": {
    "exit_code": 0,
    "output": "after_review not run: review_status is changes_requested",
    "duration_ms": 0
  }
}
```

Write `rejected` in `output` for a rejected review. The server checks only that `exit_code`, `output` and `duration_ms` are present and that `exit_code` is `0`, so this moves the task back to Doing without your running the section. An automatic-hook plugin is the exception: it runs `## after_review` after every `mark_reviewed` call, so read [Guard after_review on the Review Decision](#guard-after_review-on-the-review-decision).

### When a Human Approves from the Review Queue

The board gives a human reviewer two ways to record a decision, and they do not leave the task in the same place:

- **The Review queue's Approve button** records `approved` and finishes the review on the spot: the server moves the task to Done, unblocks its dependents, and, when the task was a goal's last open child, starts the goal's `after_goal` grace window. No hooks are sent to anyone, and a later `mark_reviewed` call from the agent is refused with `422` because the task is no longer in Review.
- **The Review queue's Request changes button** records `changes_requested` with the reviewer's notes and leaves the task in Review for the agent's `mark_reviewed` call.
- **The task's Review Status field** records the decision and leaves the task in Review for the agent's `mark_reviewed` call.

So an agent waiting on a review cannot count on reaching `mark_reviewed`. Check the task with [GET /api/tasks/:id](api/get_tasks_id.md) before you call it. A task in Review and a task in Doing both show `status: in_progress`, so tell them apart by `column_id`: it is the Review column's id while the task waits for review.

| What the task shows | What to do |
|---|---|
| `status` is `completed` (it is in Done) | The review is finished. Do not call `mark_reviewed`. The server has not delivered or checked `after_review`, so run your `## after_review` section yourself if your project relies on it. If the task belongs to a goal, call [GET /api/tasks/:id/after_goal_status](api/get_tasks_id_after_goal_status.md); when `after_goal_armed` is `true`, run `## after_goal` and report it with [PATCH /api/tasks/:id/after_goal](api/patch_tasks_id_after_goal.md) before the five-minute grace window ends |
| Still in Review, `review_status` is `approved` | Run `after_review`, then call `mark_reviewed` with its result |
| Still in Review, `review_status` is `changes_requested` or `rejected` | Do **not** run `after_review`. Call `mark_reviewed` with the [placeholder `after_review_result`](#the-placeholder-after_review_result) to move the task back to Doing, then address the feedback |
| Still in Review, `review_status` is `null` or `pending` | The review is not finished; wait |

## API Integration

### Check needs_review When Claiming

When you claim a task, the response includes the `needs_review` field. The claim needs the result of the `before_doing` hook you ran first; see [POST /api/tasks/claim](api/post_tasks_claim.md) for every parameter:

```bash
curl -X POST "$STRIDE_API_URL/api/tasks/claim" \
  -H "Authorization: Bearer $STRIDE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "agent_name": "Claude Sonnet 4.5",
    "before_doing_result": {"exit_code": 0, "output": "Already up to date.", "duration_ms": 850}
  }'
```

Response:
```json
{
  "data": {
    "id": 42,
    "identifier": "W42",
    "title": "Add user authentication",
    "needs_review": true,
    "status": "in_progress",
    ...
  },
  "hook": {
    "name": "before_doing",
    "env": {
      "TASK_NEEDS_REVIEW": "true",
      ...
    }
  }
}
```

### Complete Task and Check Response

When completing, check the response to determine next action. This is the smallest body every mode accepts; [PATCH /api/tasks/:id/complete](api/patch_tasks_id_complete.md#completion-validation-format-g65) has the full field reference, and a dispatched `reviewer_result` must carry the full report in [completion-contract.md](completion-contract.md):

```bash
curl -X PATCH "$STRIDE_API_URL/api/tasks/W42/complete" \
  -H "Authorization: Bearer $STRIDE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "agent_name": "Claude Sonnet 4.5",
    "completion_summary": "Added OAuth2 login with refresh tokens.",
    "actual_complexity": "medium",
    "actual_files_changed": "lib/my_app/auth.ex, test/my_app/auth_test.exs",
    "time_spent_minutes": 45,
    "completion_notes": "All tests passing",
    "after_doing_result": {"exit_code": 0, "output": "230 tests, 0 failures", "duration_ms": 45678},
    "before_review_result": {"exit_code": 0, "output": "PR created", "duration_ms": 2340},
    "explorer_result": {"dispatched": false, "reason": "self_reported_exploration",
      "summary": "Read the key files and their tests inline; the change follows the existing context pattern."},
    "reviewer_result": {"dispatched": false, "reason": "self_reported_review",
      "summary": "Re-read the diff against every acceptance criterion and pitfall; no issues found."}
  }'
```

Response includes `needs_review`:
```json
{
  "data": {
    "id": 42,
    "needs_review": true,
    "status": "in_progress",
    ...
  },
  "hooks": [
    {"name": "after_doing", ...},
    {"name": "before_review", ...}
  ]
}
```

With `needs_review: true` the `hooks` list holds `after_doing` and `before_review`. With `needs_review: false` it adds `after_review`, and the task is already in Done. Either way, an `after_goal` entry is appended when the task was the last open child of a goal.

**Decision logic:**
```python
if response["data"]["needs_review"] == False:
    # Task moved to Done
    # IMMEDIATELY claim next task
    claim_next_task()
else:
    # Task moved to Review
    # STOP and wait for human review
    print("Task in review - stopping work")
```

## Hook Behavior with needs_review

### Review Hooks Execute Regardless

**Important**: Review hooks (`before_review`, `after_review`) execute even when `needs_review = false`.

This design allows:
- Automated quality checks always run
- Consistent workflow execution
- Hooks can conditionally adapt using `TASK_NEEDS_REVIEW` env var

### Which Response Carries Each Hook

Every hook is blocking, and the server sends each one's `timeout` in milliseconds (`600000` today); the full table is in [Four Fixed Hook Points](AGENT-HOOK-EXECUTION-GUIDE.md#four-fixed-hook-points). Which response hands you a hook depends on `needs_review`:

| Hook | `needs_review = false` | `needs_review = true` |
|------|------------------------|-----------------------|
| `before_doing` | Claim response | Claim response |
| `after_doing`, `before_review` | `/complete` response — you run both before the call and send their results with it | Same |
| `after_review` | `/complete` response — run it after the call; nothing reports its result | Approving `/mark_reviewed` response — run it before the call, only when `review_status` is `approved`, and send `after_review_result` with it. On `changes_requested` or `rejected`, never run it; send the [placeholder](#the-placeholder-after_review_result). That response has no `hooks` list |
| `after_goal` | Appended to the `/complete` response when the task was a goal's last open child | Appended to the approving `/mark_reviewed` response when the task was a goal's last open child |

Report an `after_goal` result with [PATCH /api/tasks/:id/after_goal](api/patch_tasks_id_after_goal.md), against the goal. An `exit_code` of `0` moves the goal to Done; otherwise the goal waits for another report, or for the server to move it to Done itself when the five-minute grace window ends.

### Using TASK_NEEDS_REVIEW in Hooks

All hooks receive the `TASK_NEEDS_REVIEW` environment variable:

````markdown
# Example .stride.md hook configuration

## before_review
```bash
# Always run automated quality checks
mix test || exit 1
mix credo --strict || exit 1

# Only request human review if needed
if [ "$TASK_NEEDS_REVIEW" = "true" ]; then
  echo "Requesting human review for task $TASK_IDENTIFIER"
  # Send Slack notification to reviewers
  curl -X POST https://slack.com/api/chat.postMessage \
    -d "text=Task $TASK_IDENTIFIER requires review: $TASK_TITLE" \
    -d "channel=#code-review"
else
  echo "Task $TASK_IDENTIFIER auto-approved (no review required)"
fi
```

## after_review
```bash
# Runs only after an approval: the agent runs this section when the task
# went straight to Done (needs_review=false) or its review_status is
# "approved". On changes_requested or rejected the agent never runs it.
# The hook env has no review status, so this script cannot check that itself.
if [ "$TASK_NEEDS_REVIEW" = "true" ]; then
  # Manual review approved - merge PR
  gh pr merge --auto --squash
else
  # Auto-approved - merge immediately
  gh pr merge --squash
fi

# Clean up branch regardless
git checkout main
git pull origin main
```
````

`TASK_NEEDS_REVIEW` says whether the task needed a review, not what the reviewer decided, so the `## after_review` example above is safe only when the agent runs it after an approval and never on `changes_requested` or `rejected`; see [The Placeholder after_review_result](#the-placeholder-after_review_result). An agent that runs hooks by hand can keep that promise. An automatic-hook plugin cannot, so with one, use the guarded section below instead.

### Guard after_review on the Review Decision

The Claude Code and OpenCode plugins run `## after_review` after **every** `mark_reviewed` call (see the routing tables in [Automatic Hook Execution via Claude Code Hooks](AGENT-HOOK-EXECUTION-GUIDE.md#automatic-hook-execution-via-claude-code-hooks-stride-plugin-v150)), including the placeholder call that sends a `changes_requested` or `rejected` task back to Doing. The plugins do not check the decision, and the hook environment does not carry it, so the section has to ask for it before it merges or deploys anything:

````markdown
## after_review
```bash
# Plugins run this section after every mark_reviewed call, so check the decision.
# review_status is kept on the task after it moves back to Doing.
# Only an explicit needs_review=false skips the check: an unset value does not.
if [ "$TASK_NEEDS_REVIEW" != "false" ]; then
  REVIEW_STATUS=$(curl -s -H "Authorization: Bearer $STRIDE_API_TOKEN" \
    "$STRIDE_API_URL/api/tasks/$TASK_ID" | jq -r '.data.review_status')
  if [ "$REVIEW_STATUS" != "approved" ]; then
    echo "after_review skipped: review_status is $REVIEW_STATUS"
    exit 0
  fi
fi
gh pr merge --squash
```
````

The check fails closed: when `TASK_NEEDS_REVIEW`, `TASK_ID`, `STRIDE_API_URL` or `STRIDE_API_TOKEN` is missing from the hook's environment, or the request fails, `REVIEW_STATUS` is not `approved` and nothing is merged. Only a task whose `TASK_NEEDS_REVIEW` is exactly `false` skips the check, because it has no review decision, and its section runs as before.

## Continuous Work Loop

**Recommended:** Use the `stride-workflow` orchestrator skill for the complete lifecycle. It walks through claim → explore → implement → review → complete in a single skill and handles the continuous loop automatically.

**The workflow IS the automation. Every step exists because skipping it caused failures. Following every step IS the fast path.**

Agents should work continuously through the full workflow — do not prompt the user between steps, but do not skip steps either:

```
┌─────────────────────────────────────┐
│ 1. Execute before_doing hook        │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ 2. Claim task from Ready            │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ 3. Complete work                    │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ 4. Execute after_doing hook         │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ 5. Execute before_review hook       │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ 6. Call /complete with both results │
└──────────────┬──────────────────────┘
               │
               ▼
       ┌───────┴────────┐
       │                │
       ▼                ▼
needs_review?     needs_review?
    false             true
       │                │
       ▼                ▼
┌─────────────┐  ┌──────────────┐
│ Task moves  │  │ Task moves   │
│ to Done     │  │ to Review    │
└──────┬──────┘  └──────┬───────┘
       │                │
       ▼                ▼
┌─────────────┐  ┌──────────────┐
│ Execute     │  │ STOP - wait  │
│ after_review│  │ for human    │
│ (+after_goal│  │ review       │
│ if present) │  └──────────────┘
└──────┬──────┘
       │
       ▼
┌─────────────┐
│ IMMEDIATELY │
│ claim next  │
│ task        │
└──────┬──────┘
       │
       └──────► (back to step 1)
```

## Review Report

The `review_report` field allows agents to persist structured review findings on a task. This field is:

- **Optional** — set during task completion via the `PATCH /api/tasks/:id/complete` endpoint
- **Text field** — can store long-form structured reports (e.g., markdown-formatted review findings)
- **Visible in UI** — displayed in the task detail view when present, with whitespace-preserving formatting
- **Returned in API** — included in all task JSON responses (`GET /api/tasks/:id`, etc.)

### How It Works

When a task-reviewer agent reviews code changes, it produces a structured report covering acceptance criteria status, pitfall verification, and pattern compliance. This report can be included in the completion request:

```json
PATCH /api/tasks/:id/complete
{
  "agent_name": "Claude Opus 4.6",
  "review_report": "## Review Summary\n\nApproved -- 0 issues found.\n\n### Acceptance Criteria\n| # | Criterion | Status |\n|---|-----------|--------|\n| 1 | Feature works | Met |",
  "completion_summary": "Feature implemented",
  "actual_complexity": "small",
  "actual_files_changed": "lib/foo.ex, test/foo_test.exs",
  "time_spent_minutes": 15,
  "after_doing_result": { "exit_code": 0, "output": "...", "duration_ms": 1000 },
  "before_review_result": { "exit_code": 0, "output": "...", "duration_ms": 0 }
}
```

The example is shortened to the fields around `review_report`: the same request also needs `explorer_result` and `reviewer_result` (see [Complete Task and Check Response](#complete-task-and-check-response)). A report written by a reviewer subagent comes from a dispatched review, so its `reviewer_result` must be the dispatched shape carrying the full structured report in [completion-contract.md](completion-contract.md); `review_report` is the prose that goes with it.

The report is then visible to human reviewers in the task detail view, providing traceability for code review findings.

## Benefits

### For AI Agents

1. **Autonomy**: Complete low-risk tasks without waiting for approval
2. **Efficiency**: Faster completion of routine tasks
3. **Context Awareness**: Adapt hook behavior based on review requirements
4. **Clear Direction**: Know when to continue vs when to stop

### For Humans

1. **Focus**: Review effort on high-risk changes only
2. **Efficiency**: No need to review routine updates
3. **Control**: Explicit opt-in for tasks requiring review
4. **Flexibility**: Adjust requirements per-task

### For System

1. **Throughput**: Higher task completion rate with selective review
2. **Quality**: Automated checks still run via hooks
3. **Auditability**: Clear indication which tasks were reviewed
4. **Scalability**: Handle more tasks with same human capacity

## Examples

### Example 1: Documentation Update (Auto-Complete)

**Task Configuration:**
```json
{
  "title": "Update API documentation for /tasks endpoint",
  "needs_review": false,
  "complexity": "small"
}
```

**Workflow:**
```
1. before_doing: git pull origin main ✓
2. Agent claims task
3. Agent updates docs/api/tasks.md
4. after_doing: mix test, spell check ✓
5. before_review: Create PR ✓
6. Agent completes task
7. Task → Done
8. after_review: Auto-merge PR ✓
9. Agent immediately claims next task ← IMPORTANT
```

### Example 2: Security Feature (Requires Review)

**Task Configuration:**
```json
{
  "title": "Implement two-factor authentication",
  "needs_review": true,
  "complexity": "large"
}
```

**Workflow:**
```
1. before_doing: git pull, setup test env ✓
2. Agent claims task
3. Agent implements 2FA
4. after_doing: mix test, security scan ✓
5. before_review: Create PR, notify #security-team ✓
6. Agent completes task
7. Task → Review
8. AGENT STOPS ← Does not claim next task
9. Human reviews security implementation
10. Human approves (review_status = "approved")
11. after_review: Merge PR ✓
12. Agent calls mark_reviewed with after_review_result
13. Task → Done
```

### Example 3: Database Migration (Requires Review)

**Task Configuration:**
```json
{
  "title": "Add indexes to users table",
  "needs_review": true,
  "complexity": "medium"
}
```

**Workflow:**
```
1. before_doing: git pull, verify DB connection ✓
2. Agent claims task
3. Agent writes migration
4. after_doing: Validate migration syntax ✓
5. before_review: Create PR with migration plan ✓
6. Agent completes task
7. Task → Review
8. AGENT STOPS ← Does not claim next task
9. Human reviews migration (reversibility, performance)
10. Human approves after DB audit
11. after_review: Run migration in staging ✓
12. Agent calls mark_reviewed with after_review_result
13. Task → Done
```

### Example 4: Complete Goal with Dependencies (Auto-Complete)

This example shows the continuous work loop completing an entire goal with 3 dependent tasks.

**Initial Setup:** create the goal and its three tasks in one [POST /api/tasks](api/post_tasks.md) request. The body's root key is `task`, the server assigns every identifier, and each child names the tasks it depends on by their position in the `tasks` list (`0` is the first):

```json
{
  "task": {
    "title": "Add search feature",
    "type": "goal",
    "complexity": "large",
    "tasks": [
      {
        "title": "Add search schema",
        "type": "work",
        "complexity": "small",
        "needs_review": false
      },
      {
        "title": "Build search UI",
        "type": "work",
        "complexity": "medium",
        "needs_review": false,
        "dependencies": [0]
      },
      {
        "title": "Add search tests",
        "type": "work",
        "complexity": "small",
        "needs_review": false,
        "dependencies": [0, 1]
      }
    ]
  }
}
```

The walkthrough below calls the goal G1 and its tasks W1, W2 and W3. Those are stand-ins: the real identifiers are whatever the server returns.

**Continuous Workflow Execution:**

```
Human: "Please start working on the search feature"

Agent: Claims W1 (only unblocked task)
  POST /api/tasks/claim
  → Task W1 claimed, status: in_progress

Agent: Completes W1
  - Implements search schema
  - Runs tests ✓
  - Completes task
  → Task W1 moves to Done
  → W2 unblocks (W1 dependency satisfied)
  → W3 still blocked (needs W1 AND W2)

Agent: IMMEDIATELY queries next (no human prompt needed)
  GET /api/tasks/next
  → Returns W2 (now unblocked)

Agent: Claims and completes W2
  POST /api/tasks/claim (W2)
  - Builds search UI
  - Runs tests ✓
  - Completes task
  → Task W2 moves to Done
  → W3 unblocks (all dependencies satisfied)

Agent: IMMEDIATELY queries next
  GET /api/tasks/next
  → Returns W3

Agent: Claims and completes W3
  POST /api/tasks/claim (W3)
  - Adds comprehensive search tests
  - Runs full test suite ✓
  - Completes task
  → Task W3 moves to Done
  → The /complete response's hooks list carries after_goal (W3 was G1's last open child)

Agent: Runs the after_goal section and reports it
  PATCH /api/tasks/G1/after_goal (exit_code 0)
  → Goal G1 moves to Done

Agent: IMMEDIATELY queries next
  GET /api/tasks/next
  → 404 Not Found (no more tasks)

Agent: "Search feature complete! All 3 tasks finished and Goal G1 moved to Done."

Total human interactions: 1 (initial prompt only)
Total tasks completed: 3
Total time: Continuous execution, no waiting between tasks
```

**Key Points:**
- Agent works continuously through all 3 tasks
- Dependencies automatically unblock as tasks complete
- Goal moves to Done once the agent reports a successful `after_goal` run, or when the five-minute grace window ends after its last child completes
- Human only needed at start - agent handles entire workflow
- Each task had `needs_review: false` allowing continuous work

## Common Mistakes to Avoid

### ❌ Don't Skip Review Hooks for Auto-Complete Tasks

**Wrong:**
```python
if task["needs_review"] == False:
    # Skip all review hooks
    mark_complete_and_move_to_done()
```

**Correct:**
```python
# Execute every hook the response lists, in order (needs_review=false shown;
# with needs_review=true, after_review waits for mark_reviewed)
execute_hook("after_doing")
execute_hook("before_review")  # Still runs even if needs_review=false
response = complete_task()     # Send both results; the response lists the hooks
if task["needs_review"] == False:
    execute_hook("after_review")   # Still runs even if needs_review=false
    if has_hook(response, "after_goal"):
        execute_hook("after_goal") # Only when this task finished its goal
    claim_next_task()  # Continue working
```

### ❌ Don't Continue Working After Completing Review Task

**Wrong:**
```python
complete_task()
# Always claim next regardless of needs_review
claim_next_task()
```

**Correct:**
```python
response = complete_task()
if response["data"]["needs_review"] == False:
    claim_next_task()  # Only claim next if no review needed
else:
    print("Stopping - task requires human review")
```

### ❌ Don't Assume All Tasks Need Review

**Wrong:**
```python
# Always stop after completing any task
complete_task()
print("Waiting for review...")
```

**Correct:**
```python
response = complete_task()
if response["data"]["needs_review"]:
    print("Waiting for human review...")
else:
    print("Auto-completed, claiming next task...")
    claim_next_task()
```

## Testing Review Workflow

When testing, verify both paths:

**Test 1: Auto-Complete Path**
```bash
# Create task with needs_review=false
# Complete task
# Verify all hooks execute
# Verify task moves to Done (not Review)
# Verify agent claims next task immediately
```

**Test 2: Review Required Path**
```bash
# Create task with needs_review=true
# Complete task
# Verify all hooks execute
# Verify task moves to Review
# Verify agent stops (does not claim next)
# Human approves in the task's Review Status field
# Verify after_review hook executes
# Agent calls mark_reviewed with after_review_result
# Verify task moves to Done
# (An Approve from the Review queue moves it to Done without mark_reviewed)
```

**Test 3: Changes Requested Path**
```bash
# Create task with needs_review=true
# Complete task
# Human clicks Request changes in the Review queue (task stays in Review)
# Verify the agent does NOT run after_review
# Agent calls mark_reviewed with the placeholder after_review_result
# Verify task moves back to Doing, still assigned to the agent
```

## Summary

The `needs_review` field provides flexible control over the review process:

- **Default false**: Most tasks auto-complete for efficiency
- **Opt-in true**: High-risk tasks require human review
- **Hooks always run**: Quality checks execute regardless
- **Clear workflow**: Agents know when to continue vs stop
- **TASK_NEEDS_REVIEW**: Hooks can adapt behavior conditionally

Remember: **If `needs_review = false`, proceed to the next task. Do not prompt the user — but do not skip the exploration and review phases of the next task either. Following every step IS the fast path.**

## See Also

- [Agent Hook Execution Guide](AGENT-HOOK-EXECUTION-GUIDE.md) - Detailed hook execution
- [API Documentation](api/README.md) - Complete API reference
- [Task Writing Guide](TASK-WRITING-GUIDE.md) - Writing effective tasks
