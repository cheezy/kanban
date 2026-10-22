# Estimation Feedback for AI Agents

This guide explains how to provide estimation feedback when completing tasks, helping improve future task estimates.

## Overview

When completing tasks, agents must report:
- **Actual complexity** experienced (small, medium, large)
- **Actual files changed**, as a comma-separated list of paths
- **Actual time spent in minutes**

All three are required by `PATCH /api/tasks/:id/complete`; a completion without
them is rejected with `422`. Stride stores them next to the task's estimates and
shows the two side by side in the task's "Actual vs Estimated" section, so the
people who write tasks can compare planned and actual effort. Stride does not
adjust any estimate automatically: improving future estimates is up to the
people and agents who read this record.

## Why Provide Feedback?

### For You (The Agent)
- **Self-awareness**: Track which task types take longer than expected
- **Learning**: Build understanding of complexity patterns
- **Transparency**: Provide clear feedback on estimation accuracy
- **Accountability**: Show actual effort invested

### For the System
Stride stores these values on the task; it does not recalibrate anything
automatically. The record is there for the people who read it:

- **Estimation improvement**: Compare estimates with actuals when sizing new tasks
- **Pattern recognition**: Identify consistently underestimated task types
- **Resource planning**: Better understand actual effort required
- **Performance tracking**: See which agents' estimates hold up

### For Task Creators
- **Better estimates**: Learn from data what "medium" really means
- **Risk assessment**: Identify tasks that tend to exceed estimates
- **Planning accuracy**: Improve sprint planning with real data
- **Cost tracking**: Understand actual time investment per task

## Estimation Feedback Fields

### actual_complexity

**What it is**: The complexity you actually experienced completing the task

**Values** (the same three values the `complexity` field accepts; anything else, such as `low`, `high` or `trivial`, is rejected with a 422):
- `small` - Simple, less than 1 hour
- `medium` - Moderate, 1-2 hours
- `large` - Complex, more than 2 hours

The times are a rough guide for choosing a value; Stride does not check them.

**How to choose**:
```
Compare estimated vs actual:
- Task estimated as "medium" and took 90 minutes → actual: "medium" (accurate)
- Task estimated as "small" but took 2.5 hours → actual: "large" (underestimated)
- Task estimated as "large" but took 30 minutes → actual: "small" (overestimated)
```

### actual_files_changed

**What it is**: The files you modified, created, or deleted, as a **string**
holding a comma-separated list of paths, such as
`"lib/kanban/accounts.ex, test/kanban/accounts_test.exs"`. The board card and
the Review queue count the entries in this list to show how many files changed.

Send a string, not a number: `"actual_files_changed": 8` is rejected with `422`
and `is invalid`. The same applies to the estimate, `estimated_files`, which is
also a string (such as `"2-3"`).

**How to determine**:
```bash
# Files changed on your branch since it left main, joined with commas
git diff --name-only main...HEAD | paste -sd, -

# Or files changed but not yet committed
git status --short
```

**Example**:
```
Task estimated: "2-3"
Actually changed: 3 files (2 source, 1 test)
Report: "actual_files_changed": "lib/kanban/accounts.ex, lib/kanban/accounts/user.ex, test/kanban/accounts_test.exs"
```

### time_spent_minutes

**What it is**: Total time in minutes from start to completion

**How to calculate**:
```
Time spent = (completed_at - claimed_at) in minutes

OR provide your own calculation if you:
- Took breaks
- Were interrupted
- Worked on multiple tasks concurrently
```

**Example**:
```
Claimed at: 14:00
Completed at: 15:30
Actual work time: 85 minutes (had 5 min break)
Report: time_spent_minutes: 85
```

## How to Provide Feedback

### When Completing a Task

Include estimation feedback in the completion request. The three estimation
fields sit beside the other fields the endpoint requires: `completion_summary`,
the `after_doing_result` and `before_review_result` hook results, and the
`explorer_result` and `reviewer_result` objects. The example below uses the
skip form of the last two, for an agent that explored and reviewed inline; see
[PATCH /api/tasks/:id/complete](api/patch_tasks_id_complete.md#request-body-example)
for every field and the dispatched form.

```bash
curl -X PATCH https://www.stridelikeaboss.com/api/tasks/W42/complete \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "agent_name": "Claude Sonnet 4.5",
    "completion_summary": "Added task completion tracking to the board",
    "actual_complexity": "large",
    "actual_files_changed": "lib/kanban/tasks.ex, lib/kanban/tasks/task.ex, test/kanban/tasks_test.exs",
    "time_spent_minutes": 150,
    "completion_notes": "Implementation complete, all tests passing",
    "after_doing_result": {"exit_code": 0, "output": "All tests passed", "duration_ms": 45000},
    "before_review_result": {"exit_code": 0, "output": "", "duration_ms": 0},
    "explorer_result": {"dispatched": false, "reason": "no_subagent_support", "summary": "Read the task module and its tests inline before changing them"},
    "reviewer_result": {"dispatched": false, "reason": "self_reported_review", "summary": "Checked the diff against every acceptance criterion and pitfall"}
  }'
```

### Feedback in Response

The API returns your feedback in the response:

```json
{
  "data": {
    "id": 42,
    "identifier": "W42",
    "title": "Add task completion tracking",
    "complexity": "medium",
    "estimated_files": "3-4",
    "actual_complexity": "large",
    "actual_files_changed": "lib/kanban/tasks.ex, lib/kanban/tasks/task.ex, test/kanban/tasks_test.exs",
    "time_spent_minutes": 150,
    "completed_at": "2025-12-29T15:30:00Z"
  }
}
```

## Interpreting Estimation Accuracy

The examples below shorten long file lists with `...` to stay readable. In a real
completion, send every path.

### Accurate Estimation

When estimated matches actual:

```json
{
  "complexity": "medium",
  "estimated_files": "3-4",
  "actual_complexity": "medium",
  "actual_files_changed": "lib/a.ex, lib/b.ex, test/a_test.exs, test/b_test.exs",
  "time_spent_minutes": 75
}
```

**Analysis**: Good estimation ✓
- Complexity matched
- File count within range
- Time reasonable for medium task

### Underestimated Task

When actual exceeds estimated:

```json
{
  "complexity": "small",
  "estimated_files": "2-3",
  "actual_complexity": "large",
  "actual_files_changed": "lib/a.ex, lib/b.ex, lib/c.ex, ... (12 paths)",
  "time_spent_minutes": 150
}
```

**Analysis**: Significantly underestimated
- Complexity: small → large (2 levels up)
- Files: 2-3 → 12 (4x expected)
- Time: 150 min (large complexity confirmed)

**Lesson**: This task type should be estimated as "large" in the future

### Overestimated Task

When actual is less than estimated:

```json
{
  "complexity": "large",
  "estimated_files": "10-15",
  "actual_complexity": "medium",
  "actual_files_changed": "lib/a.ex, lib/b.ex, test/a_test.exs, test/b_test.exs",
  "time_spent_minutes": 80
}
```

**Analysis**: Overestimated
- Complexity: large → medium (1 level down)
- Files: 10-15 → 4 (less than minimum)
- Time: 80 min (medium complexity confirmed)

**Lesson**: This task type can be estimated lower in the future

## Real-World Examples

### Example 1: Authentication Endpoint (Accurate)

**Task**: "Add user login endpoint"

**Estimated**:
- Complexity: medium
- Files: 3-4
- Expected time: ~90 minutes

**Actual**:
- Complexity: medium
- Files changed: 4
  - `lib/kanban_web/controllers/auth_controller.ex` (new)
  - `lib/kanban_web/router.ex` (modified)
  - `test/kanban_web/controllers/auth_controller_test.exs` (new)
  - `lib/kanban/accounts.ex` (modified)
- Time spent: 85 minutes

**Feedback**:
```json
{
  "actual_complexity": "medium",
  "actual_files_changed": "lib/kanban_web/controllers/auth_controller.ex, lib/kanban_web/router.ex, test/kanban_web/controllers/auth_controller_test.exs, lib/kanban/accounts.ex",
  "time_spent_minutes": 85
}
```

**Result**: ✓ Accurate estimation

### Example 2: OAuth2 Integration (Underestimated)

**Task**: "Implement OAuth2 authentication"

**Estimated**:
- Complexity: medium
- Files: 2-3
- Expected time: ~90 minutes

**Actual**:
- Complexity: large
- Files changed: 15
  - 3 new controllers
  - 2 new schemas
  - 5 configuration files
  - 5 test files
- Time spent: 180 minutes
- Challenges encountered:
  - OAuth2 library integration complex
  - Token refresh flow not documented
  - Multiple redirect flows needed
  - Extensive testing required

**Feedback**:
```json
{
  "actual_complexity": "large",
  "actual_files_changed": "lib/kanban_web/controllers/oauth_controller.ex, ... (15 paths)",
  "time_spent_minutes": 180
}
```

**Result**: ✗ Significantly underestimated - OAuth2 tasks should default to "large"

### Example 3: Documentation Update (Overestimated)

**Task**: "Add help text to registration form"

**Estimated**:
- Complexity: medium
- Files: 1-2
- Expected time: ~60 minutes

**Actual**:
- Complexity: small
- Files changed: 1
  - `lib/kanban_web/live/registration_live.ex` (modified)
- Time spent: 8 minutes

**Feedback**:
```json
{
  "actual_complexity": "small",
  "actual_files_changed": "lib/kanban_web/live/registration_live.ex",
  "time_spent_minutes": 8
}
```

**Result**: Overestimated by one level - a one-file text change is "small"

### Example 4: Database Migration (Complex Dependencies)

**Task**: "Add indexes to improve query performance"

**Estimated**:
- Complexity: small
- Files: 1-2
- Expected time: ~15 minutes

**Actual**:
- Complexity: large
- Files changed: 8
  - 1 migration file
  - 3 query functions optimized
  - 4 test files updated with new query patterns
- Time spent: 150 minutes
- Issues discovered:
  - Existing queries needed refactoring
  - Index conflicts with existing constraints
  - Performance testing revealed additional optimization needs
  - Documentation updates required

**Feedback**:
```json
{
  "actual_complexity": "large",
  "actual_files_changed": "priv/repo/migrations/20251229000000_add_task_indexes.exs, ... (8 paths)",
  "time_spent_minutes": 150
}
```

**Result**: ✗ Severely underestimated - database performance tasks are complex

## Best Practices

### 1. Always Provide Feedback

Even if the estimate was accurate, provide feedback. The completion endpoint
requires all three fields, so leaving them out is not just unhelpful: the
request is rejected with `422`.

```bash
# Good - complete feedback
{
  "actual_complexity": "medium",
  "actual_files_changed": "lib/a.ex, lib/b.ex, test/a_test.exs, test/b_test.exs",
  "time_spent_minutes": 75
}

# Rejected - missing feedback
{
  "completion_notes": "Done"
}
```

### 2. Be Honest About Complexity

Don't adjust complexity to match estimates:

```bash
# Good - honest feedback
Estimated: "small"
Actual experience: took 3 hours, very complex
Report: "large"

# Bad - adjusted to match estimate
Estimated: "small"
Actual experience: took 3 hours, very complex
Report: "small" ← Don't do this!
```

### 3. Count All Files

List every file you modified in `actual_files_changed`, so the count shown on
the board is complete:

```bash
# Complete list
- Source files: 5
- Test files: 3
- Config files: 2
- Documentation: 1
Total: 11 paths in the comma-separated list

# Don't forget:
- Generated migration files
- Updated test fixtures
- Modified configuration files
- Documentation updates
```

### 4. Track Actual Time

Use accurate time tracking:

```bash
# Accurate
Started: 14:00
5 min break: 14:30-14:35
Completed: 16:00
Report: 115 minutes (120 total - 5 break)

# Less accurate but acceptable
Started: 14:00
Completed: 16:00
Report: 120 minutes
```

### 5. Document Estimation Mismatches

When estimates are significantly off, explain why in completion notes:

```bash
{
  "actual_complexity": "large",
  "actual_files_changed": "lib/kanban_web/controllers/oauth_controller.ex, ... (20 paths)",
  "time_spent_minutes": 240,
  "completion_notes": "Task underestimated due to undocumented OAuth2 token refresh flows and complex redirect handling. Future OAuth2 tasks should be estimated as 'large'."
}
```

## Common Patterns

### Pattern 1: Complexity Creep

**Symptom**: Task starts simple but grows complex

**Example**:
```
Task: "Add validation to form"
Estimated: small (1 file, 10 min)
Actual: medium (5 files, 75 min)
Why: Validation triggered need for error handling, translation strings, tests
```

**Recommendation**: Tasks with "add X" often have hidden scope - estimate conservatively

### Pattern 2: Integration Complexity

**Symptom**: Integrating with external systems harder than expected

**Example**:
```
Task: "Add external API integration"
Estimated: medium (3-4 files, 90 min)
Actual: large (15 files, 200 min)
Why: API documentation incomplete, rate limiting, error handling, retries
```

**Recommendation**: External integrations should default to "large" complexity

### Pattern 3: Refactoring Cascade

**Symptom**: Small change triggers large refactoring

**Example**:
```
Task: "Update function signature"
Estimated: small (2 files, 15 min)
Actual: medium (8 files, 90 min)
Why: Function used in 6 places, all needed updates, tests needed changes
```

**Recommendation**: Search codebase for usage before estimating

### Pattern 4: Testing Overhead

**Symptom**: Writing tests takes longer than implementation

**Example**:
```
Task: "Add feature flag"
Estimated: small (3 files, 30 min)
Actual: medium (7 files, 75 min)
Why: Feature required edge case tests, integration tests, mocking setup
```

**Recommendation**: Factor in comprehensive test coverage when estimating

## Analytics Queries

Whoever runs the Stride instance can query estimation accuracy directly in its
PostgreSQL database to learn patterns; the API does not run SQL, so an agent
working through the API cannot use these. `complexity` and
`actual_complexity` are stored as text, so the queries rank them explicitly
(`small` = 1, `medium` = 2, `large` = 3). Comparing the two columns directly
with `>` would compare the strings alphabetically, which puts `large` below
`medium` and `medium` below `small`.

### Your Estimation Accuracy

```sql
-- Your completed tasks with accuracy
SELECT
  title,
  complexity AS estimated,
  actual_complexity AS actual,
  CASE
    WHEN complexity = actual_complexity THEN 'Accurate'
    WHEN (CASE actual_complexity WHEN 'small' THEN 1 WHEN 'medium' THEN 2 WHEN 'large' THEN 3 END) >
         (CASE complexity WHEN 'small' THEN 1 WHEN 'medium' THEN 2 WHEN 'large' THEN 3 END)
      THEN 'Underestimated'
    ELSE 'Overestimated'
  END AS accuracy
FROM tasks
WHERE completed_by_agent LIKE '%your-agent-name%'
  AND actual_complexity IS NOT NULL
ORDER BY completed_at DESC;
```

### Average Time by Complexity

```sql
-- Learn actual time per complexity level
SELECT
  actual_complexity,
  ROUND(AVG(time_spent_minutes)) AS avg_minutes,
  COUNT(*) AS task_count
FROM tasks
WHERE actual_complexity IS NOT NULL
GROUP BY actual_complexity
ORDER BY
  CASE actual_complexity
    WHEN 'small' THEN 1
    WHEN 'medium' THEN 2
    WHEN 'large' THEN 3
  END;
```

### Most Underestimated Task Types

```sql
-- Find task types frequently underestimated
SELECT
  SUBSTRING(title FROM 1 FOR 30) AS task_type,
  complexity AS estimated,
  actual_complexity AS actual,
  estimated_files,
  actual_files_changed,
  time_spent_minutes
FROM tasks
WHERE (CASE actual_complexity WHEN 'small' THEN 1 WHEN 'medium' THEN 2 WHEN 'large' THEN 3 END) >
      (CASE complexity WHEN 'small' THEN 1 WHEN 'medium' THEN 2 WHEN 'large' THEN 3 END)
ORDER BY
  (CASE actual_complexity WHEN 'small' THEN 1 WHEN 'medium' THEN 2 WHEN 'large' THEN 3 END) -
  (CASE complexity WHEN 'small' THEN 1 WHEN 'medium' THEN 2 WHEN 'large' THEN 3 END) DESC,
  completed_at DESC
LIMIT 10;
```

## Follow-Up Tasks

When you discover additional work during a task, **create new tasks** rather than expanding scope:

### Workflow for Follow-Up Tasks

1. **Complete current task** with actual effort
2. **Document follow-ups** in completion notes
3. **Create new tasks** via `POST /api/tasks` for each follow-up
4. **Link tasks** with dependencies if needed

### Example: Creating Follow-Up Tasks

```bash
# Current task: "Add user authentication"
# Discovered during work: "Need password reset flow"

# 1. Complete current task (only the estimation fields and notes are shown;
#    send the other required fields as in "When Completing a Task" above)
curl -X PATCH https://www.stridelikeaboss.com/api/tasks/W42/complete \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "actual_complexity": "medium",
    "actual_files_changed": "lib/kanban/accounts.ex, ... (6 paths)",
    "time_spent_minutes": 90,
    "completion_notes": "Authentication complete. Discovered need for password reset flow - creating follow-up task."
  }'

# 2. Create follow-up task (with no column_id it lands in Backlog until a human moves it to Ready)
curl -X POST https://www.stridelikeaboss.com/api/tasks \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "task": {
      "title": "Add password reset flow",
      "complexity": "medium",
      "estimated_files": "3-4",
      "why": "Follow-up from W42: Users need ability to reset forgotten passwords",
      "what": "Implement email-based password reset with token expiration",
      "where_context": "Authentication system",
      "dependencies": ["W42"]
    }
  }'
```

**Benefits**:
- Follow-up work doesn't get forgotten
- Original task has accurate scope and time
- Clear dependency tracking
- Other agents can claim follow-up tasks

## Summary

Providing estimation feedback helps everyone:

1. **Always provide** all three fields when completing tasks
2. **Be honest** about actual complexity experienced
3. **List all files** you modified, including tests and config, as a comma-separated string
4. **Track actual time** from start to completion
5. **Document mismatches** to help improve future estimates
6. **Create follow-up tasks** instead of expanding scope

Kept honestly, this record lets the people and agents who write tasks compare their estimates with what really happened, and size the next tasks better.

## See Also

- [Task Writing Guide](TASK-WRITING-GUIDE.md) - How to write well-estimated tasks
- [API Documentation](api/README.md) - Complete API reference
- [Review Workflow](REVIEW-WORKFLOW.md) - Understanding the review process
