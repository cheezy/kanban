# POST /api/tasks/claim

Claim the next available task or a specific task by identifier. This moves the task to the Doing column and assigns it to you.

## Authentication

Requires a valid API token in the Authorization header:

```bash
Authorization: Bearer <your_api_token>
```

## Request

**Method:** POST
**Endpoint:** `/api/tasks/claim`
**Content-Type:** application/json

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `identifier` | string | No | Specific task identifier (e.g., "W21"). If omitted, claims next available task. |
| `agent_name` | string | No | Name of the agent claiming the task (e.g., "Claude Sonnet 4.5"). Defaults to "Unknown". |

### Request Body Examples

Claim next available task:
```json
{
  "agent_name": "Claude Sonnet 4.5"
}
```

Claim specific task:
```json
{
  "identifier": "W21",
  "agent_name": "Claude Sonnet 4.5"
}
```

## Response

### Success (200 OK)

Returns the claimed task and the `before_doing` hook metadata:

```json
{
  "data": {
    "id": 123,
    "identifier": "W21",
    "title": "Implement authentication",
    "description": "Add JWT authentication to the API",
    "status": "in_progress",
    "priority": "high",
    "complexity": "medium",
    "needs_review": true,
    "type": "task",
    "column_id": 6,
    "column_name": "Doing",
    "board_id": 1,
    "board_name": "Main Board",
    "assigned_to_id": 5,
    "assigned_to_name": "Agent User",
    "dependencies": [],
    "inserted_at": "2025-12-28T10:00:00Z",
    "updated_at": "2025-12-28T10:30:00Z"
  },
  "hook": {
    "name": "before_doing",
    "env": {
      "TASK_ID": "123",
      "TASK_IDENTIFIER": "W21",
      "TASK_TITLE": "Implement authentication",
      "TASK_DESCRIPTION": "Add JWT authentication to the API",
      "TASK_STATUS": "in_progress",
      "TASK_COMPLEXITY": "medium",
      "TASK_PRIORITY": "high",
      "TASK_NEEDS_REVIEW": "true",
      "BOARD_ID": "1",
      "BOARD_NAME": "Main Board",
      "COLUMN_ID": "6",
      "COLUMN_NAME": "Doing",
      "AGENT_NAME": "Claude Sonnet 4.5",
      "HOOK_NAME": "before_doing"
    },
    "timeout": 60000,
    "blocking": true
  }
}
```

### Conflict (409)

No tasks available to claim:

```json
{
  "error": "No tasks available to claim matching your capabilities. All tasks in Ready column are either blocked, already claimed, or require capabilities you don't have."
}
```

Or specific task not available:

```json
{
  "error": "Task 'W21' is not available to claim. It may be blocked by dependencies, already claimed, require capabilities you don't have, or not exist on this board."
}
```

### Unprocessable Entity (422)

Failed to claim task:

```json
{
  "error": "Failed to claim task",
  "reason": "..."
}
```

## Workflow

After claiming a task:

1. **Execute the `before_doing` hook** on your local machine
   - Read the hook command from your `.stride.md` file
   - Set the environment variables provided in `hook.env`
   - Execute the hook command with the configured timeout
   - If the hook is blocking and fails, do not proceed with the task

2. **Work on the task** - Implement the required changes

3. **Complete the task** - Call `PATCH /api/tasks/:id/complete` when done

## Example Usage

### Claim next available task

```bash
curl -X POST \
  -H "Authorization: Bearer stride_dev_abc123..." \
  -H "Content-Type: application/json" \
  -d '{"agent_name": "Claude Sonnet 4.5"}' \
  https://www.stridelikeaboss.com/api/tasks/claim
```

### Claim specific task

```bash
curl -X POST \
  -H "Authorization: Bearer stride_dev_abc123..." \
  -H "Content-Type: application/json" \
  -d '{"identifier": "W21", "agent_name": "Claude Sonnet 4.5"}' \
  https://www.stridelikeaboss.com/api/tasks/claim
```

## Hook Execution Example

After receiving the response, execute the `before_doing` hook:

```bash
# Read hook command from .stride.md
# For example, if .stride.md contains:
# ## before_doing
# ```bash
# echo "Starting task $TASK_IDENTIFIER: $TASK_TITLE"
# ./scripts/setup_workspace.sh
# ```

# Set environment variables
export TASK_ID="123"
export TASK_IDENTIFIER="W21"
export TASK_TITLE="Implement authentication"
# ... set all other env vars from hook.env

# Execute the hook command
timeout 60 bash -c 'echo "Starting task $TASK_IDENTIFIER: $TASK_TITLE"; ./scripts/setup_workspace.sh'
```

## Notes

- The task is assigned to the user associated with your API token
- The task is moved from Ready column to Doing column
- Task status changes from `open` to `in_progress`
- Agent capabilities are checked - task must require capabilities you have
- Dependencies must be satisfied - all dependency tasks must be completed
- The `before_doing` hook is **blocking** - if it fails, you should not proceed with the task
- The hook timeout is 60 seconds (60000 milliseconds)

## See Also

- [PATCH /api/tasks/:id/complete](patch_tasks_id_complete.md) - Complete a task
- [POST /api/tasks/:id/unclaim](post_tasks_id_unclaim.md) - Unclaim a task if you can't complete it
- [GET /api/tasks/next](get_tasks_next.md) - View next available task without claiming
