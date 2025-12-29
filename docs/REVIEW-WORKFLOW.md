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
1. Agent claims task from Ready column
2. Execute `before_doing` hook (blocking, 60s)
3. Agent completes work
4. Agent calls `/api/tasks/:id/complete`
5. Execute `after_doing` hook (blocking, 120s) - quality checks MUST pass
6. Execute `before_review` hook (non-blocking, 60s) - still runs for automation
7. Execute `after_review` hook (non-blocking, 60s) - still runs for automation
8. **Task moves directly to Done** - skips Review column
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
1. Agent claims task from Ready column
2. Execute `before_doing` hook (blocking, 60s)
3. Agent completes work
4. Agent calls `/api/tasks/:id/complete`
5. Execute `after_doing` hook (blocking, 120s) - quality checks MUST pass
6. Execute `before_review` hook (non-blocking, 60s) - create PR, notify reviewers
7. **Task moves to Review column**
8. **Task waits for human review** - agent STOPS and does not claim next task
9. Human reviews and sets `review_status` (approved/changes_requested/rejected)
10. If approved: Agent calls `/api/tasks/:id/mark_reviewed`
11. Execute `after_review` hook (non-blocking, 60s) - merge PR, deploy
12. Task moves to Done
13. If changes_requested: Task returns to Doing for agent to address feedback

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
# - Agent calls mark_reviewed
# - after_review hook merges PR ✓
# - Task moves to Done
```

## API Integration

### Check needs_review When Claiming

When you claim a task, the response includes the `needs_review` field:

```bash
curl -X POST https://www.stridelikeaboss.com/api/tasks/claim \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"agent_name": "Claude Sonnet 4.5"}'
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

When completing, check the response to determine next action:

```bash
curl -X PATCH https://www.stridelikeaboss.com/api/tasks/W42/complete \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "agent_name": "Claude Sonnet 4.5",
    "time_spent_minutes": 45,
    "completion_notes": "All tests passing"
  }'
```

Response includes `needs_review`:
```json
{
  "data": {
    "id": 42,
    "needs_review": true,
    "status": "review",
    ...
  },
  "hooks": [
    {"name": "after_doing", ...},
    {"name": "before_review", ...}
  ]
}
```

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

### Using TASK_NEEDS_REVIEW in Hooks

All hooks receive the `TASK_NEEDS_REVIEW` environment variable:

```bash
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
```

## Continuous Work Loop

Agents should work continuously until encountering a task that needs review:

```
┌─────────────────────────────────────┐
│ 1. Claim task from Ready            │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ 2. Execute before_doing hook        │
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
       ┌───────┴────────┐
       │                │
       ▼                ▼
needs_review?     needs_review?
    false             true
       │                │
       ▼                ▼
┌─────────────┐  ┌──────────────┐
│ Execute     │  │ Task moves   │
│ after_review│  │ to Review    │
│ hook        │  │              │
└──────┬──────┘  └──────┬───────┘
       │                │
       ▼                ▼
┌─────────────┐  ┌──────────────┐
│ Task moves  │  │ STOP - wait  │
│ to Done     │  │ for human    │
└──────┬──────┘  │ review       │
       │         └──────────────┘
       ▼
┌─────────────┐
│ IMMEDIATELY │
│ claim next  │
│ task        │
└──────┬──────┘
       │
       └──────► (back to step 1)
```

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
  "complexity": "trivial"
}
```

**Workflow:**
```
1. Agent claims task
2. before_doing: git pull origin main ✓
3. Agent updates docs/api/tasks.md
4. Agent completes task
5. after_doing: mix test, spell check ✓
6. before_review: Create PR ✓
7. after_review: Auto-merge PR ✓
8. Task → Done
9. Agent immediately claims next task ← IMPORTANT
```

### Example 2: Security Feature (Requires Review)

**Task Configuration:**
```json
{
  "title": "Implement two-factor authentication",
  "needs_review": true,
  "complexity": "high"
}
```

**Workflow:**
```
1. Agent claims task
2. before_doing: git pull, setup test env ✓
3. Agent implements 2FA
4. Agent completes task
5. after_doing: mix test, security scan ✓
6. before_review: Create PR, notify #security-team ✓
7. Task → Review
8. AGENT STOPS ← Does not claim next task
9. Human reviews security implementation
10. Human approves (review_status = "approved")
11. Agent calls mark_reviewed
12. after_review: Merge PR ✓
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
1. Agent claims task
2. before_doing: git pull, verify DB connection ✓
3. Agent writes migration
4. Agent completes task
5. after_doing: Validate migration syntax ✓
6. before_review: Create PR with migration plan ✓
7. Task → Review
8. AGENT STOPS ← Does not claim next task
9. Human reviews migration (reversibility, performance)
10. Human approves after DB audit
11. Agent calls mark_reviewed
12. after_review: Run migration in staging ✓
13. Task → Done
```

### Example 4: Complete Goal with Dependencies (Auto-Complete)

This example shows the continuous work loop completing an entire goal with 3 dependent tasks.

**Initial Setup:**
```json
{
  "goal": {
    "identifier": "G1",
    "title": "Add search feature",
    "tasks": [
      {
        "identifier": "W1",
        "title": "Add search schema",
        "needs_review": false,
        "dependencies": []
      },
      {
        "identifier": "W2",
        "title": "Build search UI",
        "needs_review": false,
        "dependencies": ["W1"]
      },
      {
        "identifier": "W3",
        "title": "Add search tests",
        "needs_review": false,
        "dependencies": ["W1", "W2"]
      }
    ]
  }
}
```

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
  → Goal G1 automatically moves to Done (all children complete)

Agent: IMMEDIATELY queries next
  GET /api/tasks/next
  → 204 No Content (no more tasks)

Agent: "Search feature complete! All 3 tasks finished and Goal G1 moved to Done."

Total human interactions: 1 (initial prompt only)
Total tasks completed: 3
Total time: Continuous execution, no waiting between tasks
```

**Key Points:**
- Agent works continuously through all 3 tasks
- Dependencies automatically unblock as tasks complete
- Goal automatically moves to Done when all children complete
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
# Always execute all hooks returned by the API
complete_task()  # API returns hooks
execute_hook("after_doing")
execute_hook("before_review")  # Still runs even if needs_review=false
execute_hook("after_review")   # Still runs even if needs_review=false

if task["needs_review"] == False:
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
# Human approves review
# Agent calls mark_reviewed
# Verify after_review hook executes
# Verify task moves to Done
```

## Summary

The `needs_review` field provides flexible control over the review process:

- **Default false**: Most tasks auto-complete for efficiency
- **Opt-in true**: High-risk tasks require human review
- **Hooks always run**: Quality checks execute regardless
- **Clear workflow**: Agents know when to continue vs stop
- **TASK_NEEDS_REVIEW**: Hooks can adapt behavior conditionally

Remember: **If `needs_review = false`, IMMEDIATELY claim the next task to continue working.**

## See Also

- [Agent Hook Execution Guide](AGENT-HOOK-EXECUTION-GUIDE.md) - Detailed hook execution
- [API Documentation](api/README.md) - Complete API reference
- [Task Writing Guide](TASK-WRITING-GUIDE.md) - Writing effective tasks
