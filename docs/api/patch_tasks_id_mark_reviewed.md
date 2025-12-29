# PATCH /api/tasks/:id/mark_reviewed

Mark a task in the Review column as reviewed (approved, changes requested, or rejected). This finalizes the review process.

## Authentication

Requires a valid API token in the Authorization header:

```bash
Authorization: Bearer <your_api_token>
```

## Request

**Method:** PATCH
**Endpoint:** `/api/tasks/:id/mark_reviewed`
**Content-Type:** application/json

### URL Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | string | Yes | Task ID (numeric) or task identifier (e.g., "W21") |

### Request Body

This endpoint does NOT accept a request body. The review decision must already be set on the task via the web UI by a human reviewer.

## Response

### Success (200 OK)

The behavior depends on the review status:

**If approved** - Task moves to Done column:

```json
{
  "data": {
    "id": 123,
    "identifier": "W21",
    "title": "Implement authentication",
    "description": "Add JWT authentication to the API",
    "status": "completed",
    "priority": "high",
    "complexity": "medium",
    "needs_review": true,
    "type": "task",
    "column_id": 8,
    "column_name": "Done",
    "board_id": 1,
    "board_name": "Main Board",
    "review_status": "approved",
    "completed_at": "2025-12-28T12:00:00Z",
    "inserted_at": "2025-12-28T10:00:00Z",
    "updated_at": "2025-12-28T12:00:00Z"
  },
  "hook": {
    "name": "after_review",
    "env": {
      "TASK_ID": "123",
      "TASK_IDENTIFIER": "W21",
      "TASK_TITLE": "Implement authentication",
      "TASK_STATUS": "completed",
      "TASK_COMPLEXITY": "medium",
      "TASK_PRIORITY": "high",
      "BOARD_ID": "1",
      "BOARD_NAME": "Main Board",
      "COLUMN_ID": "8",
      "COLUMN_NAME": "Done",
      "AGENT_NAME": "Unknown",
      "HOOK_NAME": "after_review"
    },
    "timeout": 60000,
    "blocking": false
  }
}
```

**If changes requested or rejected** - Task moves back to Doing column:

```json
{
  "data": {
    "id": 123,
    "identifier": "W21",
    "title": "Implement authentication",
    "status": "in_progress",
    "column_id": 6,
    "column_name": "Doing",
    "review_status": "changes_requested",
    "updated_at": "2025-12-28T12:00:00Z"
  }
}
```

### Unprocessable Entity (422)

Task is not in Review column:

```json
{
  "error": "Task must be in Review column to mark as reviewed"
}
```

Review status not set:

```json
{
  "error": "Task must have a review status before being marked as reviewed"
}
```

Invalid review status:

```json
{
  "error": "Invalid review status. Must be 'approved', 'changes_requested', or 'rejected'"
}
```

## Workflow

1. **Human reviewer reviews the task** via the web UI
   - They examine the work, test the changes, review code, etc.
   - They set the review status to: `approved`, `changes_requested`, or `rejected`

2. **Agent calls this endpoint** to finalize the review

3. **If approved:**
   - Task moves to Done column
   - Task status changes to `completed`
   - `completed_at` timestamp is set
   - Parent goal (if any) may also move to Done
   - Dependent tasks are unblocked
   - Returns `after_review` hook metadata

4. **If changes requested or rejected:**
   - Task moves back to Doing column
   - Task status changes back to `in_progress`
   - Task remains assigned to the same agent
   - No hook is returned

5. **Execute `after_review` hook** (if approved, non-blocking, 60s timeout)
   - This hook runs after successful review
   - Example: Deploy to production, notify stakeholders, update documentation
   - Failures are logged but don't prevent task from being marked done

## Example Usage

### Mark task as reviewed

```bash
curl -X PATCH \
  -H "Authorization: Bearer stride_dev_abc123..." \
  -H "Content-Type: application/json" \
  https://www.stridelikeaboss.com/api/tasks/W21/mark_reviewed
```

### With numeric ID

```bash
curl -X PATCH \
  -H "Authorization: Bearer stride_dev_abc123..." \
  -H "Content-Type: application/json" \
  https://www.stridelikeaboss.com/api/tasks/123/mark_reviewed
```

## Hook Execution Example

If the task was approved, execute the `after_review` hook:

```bash
# Set environment variables from hook.env
export TASK_ID="123"
export TASK_IDENTIFIER="W21"
export HOOK_NAME="after_review"
# ... set all env vars

# Read hook command from .stride.md and execute with 60s timeout
# This is NON-BLOCKING - log errors but don't fail
timeout 60 bash -c './scripts/deploy_to_production.sh' || echo "after_review hook failed but task is still done"
```

## Notes

- The review status must be set by a human reviewer BEFORE calling this endpoint
- You cannot set the review status via the API - it must be done through the web UI
- Valid review statuses: `approved`, `changes_requested`, `rejected`
- If approved, the task automatically moves to Done and unblocks dependent tasks
- If changes requested/rejected, the task moves back to Doing for rework
- The `after_review` hook is **non-blocking** - failures are logged but don't prevent completion
- Parent goals automatically move to Done when all child tasks are complete
- This is typically called by an agent polling for review completion, not immediately after `complete`

## Typical Agent Workflow

1. Complete task: `PATCH /api/tasks/:id/complete`
2. Execute `after_doing` and `before_review` hooks
3. Wait for human review (poll periodically or use webhooks)
4. When review is complete, call `PATCH /api/tasks/:id/mark_reviewed`
5. If approved, execute `after_review` hook
6. If changes requested, fix issues and complete again

## See Also

- [PATCH /api/tasks/:id/complete](patch_tasks_id_complete.md) - Complete a task to send it for review
- [PATCH /api/tasks/:id/mark_done](patch_tasks_id_mark_done.md) - Directly mark a task as done (bypasses review finalization)
- [GET /api/tasks/:id](get_tasks_id.md) - Check task status and review_status
