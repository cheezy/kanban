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

### Request Body Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `after_review_result` | object | **Yes** | Result of executing the `after_review` hook. Must include `exit_code`, `output`, and `duration_ms`. |

**IMPORTANT:** You must execute the `after_review` hook BEFORE calling this endpoint and include the execution result in your request.

### Hook Result Format

The `after_review_result` parameter must be an object with these fields:

```json
{
  "exit_code": 0,
  "output": "Hook execution output (stdout/stderr combined)",
  "duration_ms": 1234
}
```

- `exit_code`: Must be `0` for success. Non-zero exit codes will be rejected.
- `output`: String containing the output from hook execution (e.g., deployment logs, notification confirmations)
- `duration_ms`: Time taken to execute the hook in milliseconds

**Note:** The review decision must already be set on the task via the web UI by a human reviewer.

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
    "blocking": true
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

Hook validation failed (missing or invalid `after_review_result`):

```json
{
  "error": "after_review hook result is required",
  "hook": "after_review",
  "documentation": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/AGENT-HOOK-EXECUTION-GUIDE.md",
  "required_format": {
    "after_review_result": {
      "exit_code": 0,
      "output": "Hook execution output",
      "duration_ms": 1234
    }
  }
}
```

Or hook execution failed with non-zero exit code:

```json
{
  "error": "after_review is a blocking hook and failed with exit code 1. Fix the issues and try again.",
  "hook": "after_review",
  "documentation": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/AGENT-HOOK-EXECUTION-GUIDE.md"
}
```

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

**CRITICAL: Hook execution is mandatory!** Follow this workflow:

1. **Human reviewer reviews the task** via the web UI
   - They examine the work, test the changes, review code, etc.
   - They set the review status to: `approved`, `changes_requested`, or `rejected`

2. **Execute the `after_review` hook FIRST** (blocking, 60s timeout)
   - This hook typically handles deployment, notifications, or finalization
   - Example: Deploy to production, notify stakeholders, update changelog
   - Capture the exit code, output, and duration
   - If hook fails (non-zero exit code), fix the issues before proceeding

3. **Call the mark_reviewed endpoint** - Include the hook execution result
   - Hook must have succeeded (exit code 0)
   - Include `after_review_result` in request
   - If hook failed, do NOT call the endpoint - fix the issues first

4. **If approved:**
   - Task moves to Done column
   - Task status changes to `completed`
   - `completed_at` timestamp is set
   - Parent goal (if any) may also move to Done
   - Dependent tasks are unblocked

5. **If changes requested or rejected:**
   - Task moves back to Doing column
   - Task status changes back to `in_progress`
   - Task remains assigned to the same agent

## Example Usage

### Mark task as reviewed after executing hook

```bash
# Step 1: Execute after_review hook FIRST
START_TIME=$(date +%s%3N)
OUTPUT=$(timeout 60 bash -c './scripts/deploy.sh && ./scripts/notify_team.sh' 2>&1)
EXIT_CODE=$?
END_TIME=$(date +%s%3N)
DURATION=$((END_TIME - START_TIME))

# Step 2: If hook succeeded, mark as reviewed
curl -X PATCH \
  -H "Authorization: Bearer stride_dev_abc123..." \
  -H "Content-Type: application/json" \
  -d "{
    \"after_review_result\": {
      \"exit_code\": $EXIT_CODE,
      \"output\": \"$OUTPUT\",
      \"duration_ms\": $DURATION
    }
  }" \
  https://www.stridelikeaboss.com/api/tasks/W21/mark_reviewed
```

### With numeric ID

```bash
# Execute hook first
START_TIME=$(date +%s%3N)
OUTPUT=$(timeout 60 bash -c 'npm run deploy && npm run notify' 2>&1)
EXIT_CODE=$?
END_TIME=$(date +%s%3N)
DURATION=$((END_TIME - START_TIME))

# Mark reviewed with result
curl -X PATCH \
  -H "Authorization: Bearer stride_dev_abc123..." \
  -H "Content-Type: application/json" \
  -d "{
    \"after_review_result\": {
      \"exit_code\": $EXIT_CODE,
      \"output\": \"$OUTPUT\",
      \"duration_ms\": $DURATION
    }
  }" \
  https://www.stridelikeaboss.com/api/tasks/123/mark_reviewed
```

## Hook Execution Details

The `after_review` hook must be executed BEFORE calling this endpoint:

```bash
# Set environment variables from task data
export TASK_ID="123"
export TASK_IDENTIFIER="W21"
export TASK_TITLE="Implement authentication"
export HOOK_NAME="after_review"
# ... set all env vars

# Read hook command from .stride.md and execute with 60s timeout
# This is BLOCKING - must succeed for endpoint call to work
START_TIME=$(date +%s%3N)
OUTPUT=$(timeout 60 bash -c './scripts/deploy_to_production.sh' 2>&1)
EXIT_CODE=$?
END_TIME=$(date +%s%3N)
DURATION=$((END_TIME - START_TIME))

if [ $EXIT_CODE -ne 0 ]; then
  echo "after_review hook failed with exit code $EXIT_CODE"
  echo "Fix the issues before calling mark_reviewed endpoint"
  exit 1
fi
```

## Notes

- The `after_review_result` parameter is **required**
- You MUST execute the `after_review` hook BEFORE calling this endpoint
- The hook must complete successfully (exit code 0) or the mark_reviewed call will be rejected
- The review status must be set by a human reviewer BEFORE calling this endpoint
- You cannot set the review status via the API - it must be done through the web UI
- Valid review statuses: `approved`, `changes_requested`, `rejected`
- If approved, the task automatically moves to Done and unblocks dependent tasks
- If changes requested/rejected, the task moves back to Doing for rework
- The `after_review` hook is **blocking** - non-zero exit codes will cause the API to reject your request
- Hook timeout for `after_review` is 60 seconds (60000 milliseconds)
- Parent goals automatically move to Done when all child tasks are complete
- This is typically called by an agent polling for review completion, not immediately after `complete`

## Typical Agent Workflow

1. Implement the work
2. Execute `after_doing` hook (blocking, 120s timeout)
3. Execute `before_review` hook (blocking, 60s timeout)
4. Complete task: `PATCH /api/tasks/:id/complete` with both hook results
5. Wait for human review (poll periodically or use webhooks)
6. When review status is set to approved:
   - Execute `after_review` hook (blocking, 60s timeout)
   - Call `PATCH /api/tasks/:id/mark_reviewed` with hook result
7. If changes requested, fix issues and repeat from step 1

## See Also

- [PATCH /api/tasks/:id/complete](patch_tasks_id_complete.md) - Complete a task to send it for review
- [PATCH /api/tasks/:id/mark_done](patch_tasks_id_mark_done.md) - Directly mark a task as done (bypasses review finalization)
- [GET /api/tasks/:id](get_tasks_id.md) - Check task status and review_status
