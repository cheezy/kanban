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
| `id` | string | Yes | Task ID (numeric) or task identifier (e.g., "W21"). A numeric ID outside the signed 64-bit range (below -9223372036854775808 or above 9223372036854775807) returns 404, the same as an ID that names no task. |

### Request Body Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `after_review_result` | object | **Yes** | On an approval, the result of executing the `after_review` hook. On `changes_requested` or `rejected`, the placeholder below. Must include `exit_code`, `output`, and `duration_ms`. |

**IMPORTANT:** Read the task's `review_status` with [GET /api/tasks/:id](get_tasks_id.md) first. Run the `## after_review` section BEFORE calling this endpoint **only when `review_status` is `approved`**, and send its result. On `changes_requested` or `rejected`, do **not** run `## after_review`: that section typically merges or deploys, and the human did not accept the work. Send the placeholder result below instead.

The server checks `after_review_result` before it reads the review decision, so a call that sends the task back to Doing still needs a successful result. The hook environment carries no review status (only `TASK_NEEDS_REVIEW`), so a `## after_review` section cannot tell an approval from a rejection by itself. The decision to skip it is yours, made from `review_status`.

**With an automatic-hook plugin the decision is not yours.** The Claude Code and OpenCode plugins run `## after_review` after **every** `mark_reviewed` call, whatever the review decision, so sending the placeholder still runs the section. On those platforms, keep merge and deploy commands in `## after_review` behind a check of the review decision; see [Guard after_review on the Review Decision](../REVIEW-WORKFLOW.md#guard-after_review-on-the-review-decision).

### Placeholder Result for Changes Requested or Rejected

When `review_status` is `changes_requested` or `rejected`, send this body without running `## after_review`:

```json
{
  "after_review_result": {
    "exit_code": 0,
    "output": "after_review not run: review_status is changes_requested",
    "duration_ms": 0
  }
}
```

Use `rejected` in `output` for a rejected review. The server checks only that the three keys are present and that `exit_code` is `0`; `output` is free text, so say there that the section was not run.

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

**If approved** - Task moves to Done column. The response carries a `hooks` list: `[after_review]`, plus an `after_goal` entry when the task was the last open child of a goal. You ran `after_review` before this call, so its entry describes a hook you have already run. Run `after_goal` when it appears and report it with [PATCH /api/tasks/:id/after_goal](patch_tasks_id_after_goal.md), against the goal:

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
    "type": "work",
    "column_id": 8,
    "review_status": "approved",
    "review_report": null,
    "completed_at": "2025-12-28T12:00:00Z",
    "inserted_at": "2025-12-28T10:00:00Z",
    "updated_at": "2025-12-28T12:00:00Z"
  },
  "hooks": [
    {
      "name": "after_review",
      "env": {
        "TASK_ID": "123",
        "TASK_IDENTIFIER": "W21",
        "TASK_TITLE": "Implement authentication",
        "TASK_DESCRIPTION": "Add JWT authentication to the API",
        "TASK_STATUS": "completed",
        "TASK_COMPLEXITY": "medium",
        "TASK_PRIORITY": "high",
        "TASK_NEEDS_REVIEW": "true",
        "BOARD_ID": "1",
        "BOARD_NAME": "Main Board",
        "COLUMN_ID": "8",
        "COLUMN_NAME": "Done",
        "AGENT_NAME": "Unknown",
        "HOOK_NAME": "after_review"
      },
      "timeout": 600000,
      "blocking": true
    }
  ],
  "current_skills_version": "1.0"
}
```

When the task was the last open child of a goal, a second entry follows `after_review` in the same list:

```json
{
  "name": "after_goal",
  "env": { "...": "...", "HOOK_NAME": "after_goal" },
  "timeout": 600000,
  "blocking": true
}
```

**If changes requested or rejected** - Task moves back to Doing column. The response has no `hooks` list: nothing in it asks you to run `after_review`, and you should not have run it before the call either:

```json
{
  "data": {
    "id": 123,
    "identifier": "W21",
    "title": "Implement authentication",
    "status": "in_progress",
    "column_id": 6,
    "review_status": "changes_requested",
    "updated_at": "2025-12-28T12:00:00Z"
  },
  "current_skills_version": "1.0"
}
```

### Forbidden (403)

The token's user no longer has owner or modify access to the board, for example
after being made a read-only member:

```json
{
  "error": "Not authorized — board write access (owner or modify) required",
  "documentation": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/README.md",
  "getting_started": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/GETTING-STARTED-WITH-AI.md"
}
```

This is checked before the task is looked up, so the response is the same
whether the task exists and whatever state it is in.

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

This is the response after a human approved the task with the Review queue's **Approve** button, which has already moved it to Done. See [After an Approve from the Review Queue](#after-an-approve-from-the-review-queue).

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

### Not Found (404)

No task on the token's board matches the ID or identifier. A task on another
board gets the same response:

```json
{
  "error": "Task not found"
}
```

A numeric ID outside the signed 64-bit range, such as `9223372036854775808`, gets
this same 404 and body. It is never a 500, and it cannot be told apart from an ID
that names no task or a task on another board. See
[404 for out-of-range numeric IDs](README.md#404-for-out-of-range-numeric-ids).

## Workflow

**CRITICAL: Run `after_review` only for an approval.** Follow this workflow:

1. **Human reviewer reviews the task** via the web UI
   - They examine the work, test the changes, review code, etc.
   - They set the review status to: `approved`, `changes_requested`, or `rejected`

2. **Check the task** with [GET /api/tasks/:id](get_tasks_id.md)
   - `status` is `completed`: the human used the Review queue's **Approve** button and the task is already in Done. Do not call this endpoint; see [After an Approve from the Review Queue](#after-an-approve-from-the-review-queue)
   - Still in Review (its `column_id` is the Review column's): read `review_status` and go on to step 3
   - `review_status` is `null` or `pending`: the review is not finished; wait

3. **If `review_status` is `approved`, execute the `after_review` hook FIRST** (blocking, 600s timeout)
   - This hook typically handles deployment, notifications, or finalization
   - Example: Deploy to production, notify stakeholders, update changelog
   - Capture the exit code, output, and duration
   - If hook fails (non-zero exit code), fix the issues before proceeding

   **If `review_status` is `changes_requested` or `rejected`, do NOT run `## after_review`.** Build the [placeholder result](#placeholder-result-for-changes-requested-or-rejected) instead.

4. **Call the mark_reviewed endpoint** - Include `after_review_result`
   - On an approval, the hook's result, which must have succeeded (exit code 0). If the hook failed, do NOT call the endpoint - fix the issues first
   - On `changes_requested` or `rejected`, the placeholder result

5. **If approved:**
   - Task moves to Done column
   - Task status changes to `completed`
   - `completed_at` timestamp is set
   - When the task was a goal's last open child, the `hooks` list carries `after_goal`; run it and report it so the goal can move to Done
   - Dependent tasks are unblocked

6. **If changes requested or rejected:**
   - Task moves back to Doing column
   - Task status changes back to `in_progress`
   - Task remains assigned to the same agent
   - The response has no `hooks` list. Address the feedback, then complete the task again

## Example Usage

### Mark task as reviewed after executing hook

These examples are for `review_status` `approved` only. For `changes_requested` or `rejected`, see [Send the placeholder for a non-approving review](#send-the-placeholder-for-a-non-approving-review).

```bash
# Step 1: review_status is "approved" - execute after_review hook FIRST
START_TIME=$(date +%s%3N)
OUTPUT=$(timeout 600 bash -c './scripts/deploy.sh && ./scripts/notify_team.sh' 2>&1)
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
OUTPUT=$(timeout 600 bash -c 'npm run deploy && npm run notify' 2>&1)
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

### Send the placeholder for a non-approving review

```bash
# review_status is "changes_requested" or "rejected":
# do NOT run ## after_review - send the placeholder result instead
curl -X PATCH \
  -H "Authorization: Bearer stride_dev_abc123..." \
  -H "Content-Type: application/json" \
  -d '{
    "after_review_result": {
      "exit_code": 0,
      "output": "after_review not run: review_status is changes_requested",
      "duration_ms": 0
    }
  }' \
  https://www.stridelikeaboss.com/api/tasks/W21/mark_reviewed
```

The task moves back to Doing, still assigned to you.

## After an Approve from the Review Queue

A human can approve a task two ways, and they do not leave it in the same place:

- **The Review queue's Approve button** finishes the review on the spot. The server moves the task to Done, unblocks its dependents, and, when the task was a goal's last open child, starts the goal's five-minute `after_goal` grace window. No hooks are sent to anyone, and a later call to this endpoint is refused with `422` (`Task must be in Review column to mark as reviewed`) because the task is no longer in Review.
- **The task's Review Status field** records the decision and leaves the task in Review for this endpoint.

So check the task with [GET /api/tasks/:id](get_tasks_id.md) before you call this endpoint. When its `status` is `completed`, do not call it. The server has not delivered or checked `after_review`, so run your `## after_review` section yourself if your project relies on it: the human approved the work. If the task belongs to a goal, call [GET /api/tasks/:id/after_goal_status](get_tasks_id_after_goal_status.md); when `after_goal_armed` is `true`, run `## after_goal` and report it with [PATCH /api/tasks/:id/after_goal](patch_tasks_id_after_goal.md) before the grace window ends. The full decision table is in [When a Human Approves from the Review Queue](../REVIEW-WORKFLOW.md#when-a-human-approves-from-the-review-queue).

## Hook Execution Details

On an approval, the `after_review` hook must be executed BEFORE calling this endpoint. On `changes_requested` or `rejected`, skip this and send the placeholder:

```bash
# Set environment variables from task data
export TASK_ID="123"
export TASK_IDENTIFIER="W21"
export TASK_TITLE="Implement authentication"
export HOOK_NAME="after_review"
# ... set all env vars

# Read hook command from .stride.md and execute with the 600s timeout the server sent
# This is BLOCKING - must succeed for endpoint call to work
START_TIME=$(date +%s%3N)
OUTPUT=$(timeout 600 bash -c './scripts/deploy_to_production.sh' 2>&1)
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

- The `after_review_result` parameter is **required**, whatever the review decision
- When `review_status` is `approved`, you MUST execute the `after_review` hook BEFORE calling this endpoint
- When `review_status` is `changes_requested` or `rejected`, do NOT execute `## after_review`; send the [placeholder result](#placeholder-result-for-changes-requested-or-rejected)
- The result must have `exit_code` `0` or the mark_reviewed call will be rejected
- The review status must be set by a human reviewer BEFORE calling this endpoint
- You cannot set the review status via the API - it must be done through the web UI
- Valid review statuses: `approved`, `changes_requested`, `rejected`
- If approved, the task automatically moves to Done and unblocks dependent tasks
- If changes requested/rejected, the task moves back to Doing for rework
- The `after_review` hook is **blocking** - non-zero exit codes will cause the API to reject your request
- The `after_review` hook timeout the server sends is 600 seconds (600000 milliseconds)
- An approval that finishes a goal's last open child appends `after_goal` to the `hooks` list. The goal moves to Done on a successful [after_goal report](patch_tasks_id_after_goal.md), or when the five-minute grace window ends
- If the human approved from the Review queue, the task is already in Done and this endpoint returns `422`; see [After an Approve from the Review Queue](#after-an-approve-from-the-review-queue)
- This is typically called by an agent polling for review completion, not immediately after `complete`

## Typical Agent Workflow

1. Implement the work
2. Execute `after_doing` hook (blocking, 600s timeout)
3. Execute `before_review` hook (blocking, 600s timeout)
4. Complete task: `PATCH /api/tasks/:id/complete` with both hook results
5. Wait for human review (poll periodically or use webhooks)
6. Check the task with `GET /api/tasks/:id`. If its `status` is `completed`, the human approved from the Review queue and the review is finished; do not call this endpoint
7. When review status is set to approved and the task is still in Review:
   - Execute `after_review` hook (blocking, 600s timeout)
   - Call `PATCH /api/tasks/:id/mark_reviewed` with hook result
8. If changes requested or rejected:
   - Do NOT execute `after_review`
   - Call `PATCH /api/tasks/:id/mark_reviewed` with the placeholder result; the task moves back to Doing
   - Fix the issues and repeat from step 1

## See Also

- [PATCH /api/tasks/:id/complete](patch_tasks_id_complete.md) - Complete a task to send it for review
- [PATCH /api/tasks/:id/mark_done](patch_tasks_id_mark_done.md) - Directly mark a task as done (bypasses review finalization)
- [GET /api/tasks/:id](get_tasks_id.md) - Check task status and review_status
