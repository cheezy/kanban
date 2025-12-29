# PATCH /api/tasks/:id/complete

Mark a task as complete. This moves the task to the Review column (or directly to Done if `needs_review=false`).

## Authentication

Requires a valid API token in the Authorization header:

```bash
Authorization: Bearer <your_api_token>
```

## Request

**Method:** PATCH
**Endpoint:** `/api/tasks/:id/complete`
**Content-Type:** application/json

### URL Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | string | Yes | Task ID (numeric) or task identifier (e.g., "W21") |

### Request Body Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `agent_name` | string | No | Name of the agent completing the task (e.g., "Claude Sonnet 4.5"). Defaults to "Unknown". |
| `time_spent_minutes` | integer | No | Time spent on the task in minutes |
| `completion_notes` | string | No | Notes about the completion |

### Request Body Example

```json
{
  "agent_name": "Claude Sonnet 4.5",
  "time_spent_minutes": 45,
  "completion_notes": "Implemented JWT authentication with refresh tokens. All tests passing."
}
```

## Response

### Success (200 OK)

Returns the completed task and hook metadata. The number of hooks depends on the task's `needs_review` setting:

**If `needs_review=true`** (task goes to Review column):
- Returns `after_doing` and `before_review` hooks

**If `needs_review=false`** (task goes directly to Done):
- Returns `after_doing`, `before_review`, and `after_review` hooks

```json
{
  "data": {
    "id": 123,
    "identifier": "W21",
    "title": "Implement authentication",
    "description": "Add JWT authentication to the API",
    "status": "review",
    "priority": "high",
    "complexity": "medium",
    "needs_review": true,
    "type": "task",
    "column_id": 7,
    "column_name": "Review",
    "board_id": 1,
    "board_name": "Main Board",
    "assigned_to_id": 5,
    "assigned_to_name": "Agent User",
    "completed_by_agent": "ai_agent:claude-sonnet-4-5",
    "time_spent_minutes": 45,
    "completion_notes": "Implemented JWT authentication with refresh tokens. All tests passing.",
    "inserted_at": "2025-12-28T10:00:00Z",
    "updated_at": "2025-12-28T11:30:00Z"
  },
  "hooks": [
    {
      "name": "after_doing",
      "env": {
        "TASK_ID": "123",
        "TASK_IDENTIFIER": "W21",
        "TASK_TITLE": "Implement authentication",
        "TASK_DESCRIPTION": "Add JWT authentication to the API",
        "TASK_STATUS": "review",
        "TASK_COMPLEXITY": "medium",
        "TASK_PRIORITY": "high",
        "TASK_NEEDS_REVIEW": "true",
        "BOARD_ID": "1",
        "BOARD_NAME": "Main Board",
        "COLUMN_ID": "7",
        "COLUMN_NAME": "Review",
        "AGENT_NAME": "Claude Sonnet 4.5",
        "HOOK_NAME": "after_doing"
      },
      "timeout": 120000,
      "blocking": true
    },
    {
      "name": "before_review",
      "env": {
        "TASK_ID": "123",
        "TASK_IDENTIFIER": "W21",
        "TASK_TITLE": "Implement authentication",
        "TASK_STATUS": "review",
        "AGENT_NAME": "Claude Sonnet 4.5",
        "HOOK_NAME": "before_review"
      },
      "timeout": 60000,
      "blocking": false
    }
  ]
}
```

### Forbidden (403)

Trying to complete a task assigned to someone else:

```json
{
  "error": "You can only complete tasks that you are assigned to"
}
```

### Unprocessable Entity (422)

Task is not in a valid state to complete:

```json
{
  "error": "Task must be in progress or blocked to complete"
}
```

## Workflow

After completing a task:

1. **Execute the `after_doing` hook** (blocking, 120s timeout)
   - This hook typically runs tests, builds, or quality checks
   - If this hook fails, the task completion should be rolled back
   - Example: Run test suite, build project, run linters

2. **Execute the `before_review` hook** (non-blocking, 60s timeout)
   - This hook typically prepares the task for review
   - Failures are logged but don't prevent the task from being marked complete
   - Example: Generate documentation, create pull request, notify reviewers

3. **If `needs_review=false`**, also execute `after_review` hook (non-blocking, 60s timeout)
   - This hook runs when the task is automatically moved to Done
   - Example: Deploy to production, close related tickets, update documentation

4. **Wait for review** (if `needs_review=true`)
   - A human reviewer will approve or request changes
   - Call `PATCH /api/tasks/:id/mark_reviewed` to finalize

## Example Usage

### Complete a task with notes

```bash
curl -X PATCH \
  -H "Authorization: Bearer stride_dev_abc123..." \
  -H "Content-Type: application/json" \
  -d '{
    "agent_name": "Claude Sonnet 4.5",
    "time_spent_minutes": 45,
    "completion_notes": "All tests passing. Ready for review."
  }' \
  http://localhost:4000/api/tasks/W21/complete
```

### Complete a task (minimal)

```bash
curl -X PATCH \
  -H "Authorization: Bearer stride_dev_abc123..." \
  -H "Content-Type: application/json" \
  -d '{"agent_name": "Claude Sonnet 4.5"}' \
  http://localhost:4000/api/tasks/123/complete
```

## Hook Execution Example

After receiving the response, execute hooks in order:

```bash
# 1. Execute after_doing hook (BLOCKING - must succeed)
export TASK_ID="123"
export TASK_IDENTIFIER="W21"
export HOOK_NAME="after_doing"
# ... set all env vars

# Read hook command from .stride.md and execute with 120s timeout
timeout 120 bash -c './scripts/run_tests.sh && ./scripts/build.sh'

# If hook fails, report error and don't proceed

# 2. Execute before_review hook (NON-BLOCKING - log errors but continue)
export HOOK_NAME="before_review"
timeout 60 bash -c './scripts/create_pr.sh' || echo "before_review hook failed but continuing"

# 3. If needs_review=false, execute after_review hook
# Similar to before_review - non-blocking
```

## Notes

- You can only complete tasks that are assigned to you
- Task must be in `in_progress` or `blocked` status
- If `needs_review=true`, task moves to Review column with `review` status
- If `needs_review=false`, task automatically moves to Done column with `completed` status
- The `after_doing` hook is **blocking** - task completion fails if this hook fails
- The `before_review` hook is **non-blocking** - failures are logged but don't prevent completion
- Agent model from your API token is automatically recorded as `completed_by_agent`
- If the task is a goal (parent task), it will only move to Done when all child tasks are complete

## See Also

- [POST /api/tasks/claim](post_tasks_claim.md) - Claim a task to start working
- [PATCH /api/tasks/:id/mark_reviewed](patch_tasks_id_mark_reviewed.md) - Mark task as reviewed after completion
- [POST /api/tasks/:id/unclaim](post_tasks_id_unclaim.md) - Unclaim if you can't complete
