# GET /api/tasks

List all tasks on the board, optionally filtered by column.

## Authentication

Requires a valid API token in the Authorization header:

```bash
Authorization: Bearer <your_api_token>
```

## Request

**Method:** GET
**Endpoint:** `/api/tasks`

### Query Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `column_id` | integer | No | Filter tasks by column ID. If omitted, returns all tasks from all columns. |

## Response

### Success (200 OK)

Returns an array of tasks:

```json
{
  "data": [
    {
      "id": 123,
      "identifier": "W21",
      "title": "Implement authentication",
      "description": "Add JWT authentication to the API",
      "acceptance_criteria": "Users can log in with email/password\nJWT tokens are generated correctly",
      "status": "in_progress",
      "priority": "high",
      "complexity": "medium",
      "needs_review": true,
      "type": "task",
      "column_id": 6,
      "assigned_to_id": 5,
      "parent_id": null,
      "estimated_files": 3,
      "why": "Users need secure authentication",
      "what": "JWT-based login system",
      "where_context": "Authentication module",
      "patterns_to_follow": "Follow existing controller patterns",
      "database_changes": null,
      "validation_rules": null,
      "telemetry_event": null,
      "metrics_to_track": null,
      "logging_requirements": null,
      "error_user_message": null,
      "error_on_failure": null,
      "key_files": [
        {
          "file_path": "lib/kanban_web/controllers/auth_controller.ex",
          "note": "Main authentication logic",
          "position": 0
        }
      ],
      "verification_steps": [
        {
          "step_type": "command",
          "step_text": "mix test test/kanban_web/controllers/auth_controller_test.exs",
          "expected_result": "All tests pass",
          "position": 0
        }
      ],
      "technology_requirements": null,
      "pitfalls": null,
      "out_of_scope": null,
      "security_considerations": "Hash passwords with bcrypt",
      "testing_strategy": null,
      "integration_points": null,
      "created_by_id": 1,
      "created_by_agent": null,
      "completed_at": null,
      "completed_by_id": null,
      "completed_by_agent": null,
      "completion_summary": null,
      "dependencies": [],
      "claimed_at": "2025-12-28T10:30:00Z",
      "claim_expires_at": "2025-12-28T11:30:00Z",
      "required_capabilities": ["code_generation"],
      "actual_complexity": null,
      "actual_files_changed": null,
      "time_spent_minutes": null,
      "review_status": null,
      "review_notes": null,
      "reviewed_at": null,
      "reviewed_by_id": null,
      "inserted_at": "2025-12-28T10:00:00Z",
      "updated_at": "2025-12-28T11:00:00Z"
    },
    {
      "id": 124,
      "identifier": "W22",
      "title": "Fix login bug",
      "description": "Users can't log in with special characters",
      "acceptance_criteria": null,
      "status": "open",
      "priority": "medium",
      "complexity": "low",
      "needs_review": true,
      "type": "task",
      "column_id": 5,
      "assigned_to_id": null,
      "parent_id": null,
      "key_files": [],
      "verification_steps": [],
      "dependencies": [],
      "required_capabilities": [],
      "claimed_at": null,
      "claim_expires_at": null,
      "inserted_at": "2025-12-28T12:00:00Z",
      "updated_at": "2025-12-28T12:00:00Z"
    }
  ]
}
```

### Forbidden (403)

Column doesn't belong to the current board:

```json
{
  "error": "Column does not belong to this board"
}
```

## Response Field Descriptions

### Core Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | integer | Unique numeric task ID |
| `identifier` | string | Human-readable identifier (W21, G10, etc.) |
| `title` | string | Task title |
| `description` | string | Detailed description of the task |
| `acceptance_criteria` | string | Specific, testable conditions for completion (newline-separated) |
| `status` | string | Current status: `open`, `in_progress`, `blocked`, `review`, `completed` |
| `priority` | string | Priority level: `low`, `medium`, `high`, `critical` |
| `complexity` | string | Estimated complexity: `trivial`, `low`, `medium`, `high`, `very_high` |
| `needs_review` | boolean | Whether task requires human review before completion |
| `type` | string | Type: `task` or `goal` |
| `column_id` | integer | Current column ID |
| `assigned_to_id` | integer | User ID assigned to task (null if unclaimed) |
| `parent_id` | integer | ID of parent goal (null if no parent) |

### Planning & Context Fields

| Field | Type | Description |
|-------|------|-------------|
| `estimated_files` | integer | Estimated number of files to modify |
| `why` | string | Why this task matters - business justification |
| `what` | string | What needs to be done - concise summary |
| `where_context` | string | Where in the codebase this work happens |
| `patterns_to_follow` | string | Specific coding patterns to replicate (newline-separated) |
| `database_changes` | string | Database schema changes required |
| `validation_rules` | string | Input validation requirements |
| `technology_requirements` | array | Specific libraries or technologies to use (array of strings) |
| `pitfalls` | array | Common mistakes to avoid (array of strings) |
| `out_of_scope` | array | What NOT to include in this task (array of strings) |

### Implementation Guidance Fields

| Field | Type | Description |
|-------|------|-------------|
| `key_files` | array | Files that will be modified (prevents conflicts) - see structure below |
| `verification_steps` | array | Commands to run to verify success - see structure below |
| `security_considerations` | array | Security concerns or requirements (array of strings) |
| `testing_strategy` | object | Overall testing approach (JSON object) |
| `integration_points` | object | Systems or APIs this touches (JSON object) |

### Observability Fields

| Field | Type | Description |
|-------|------|-------------|
| `telemetry_event` | string | Telemetry events to emit |
| `metrics_to_track` | string | Metrics to instrument |
| `logging_requirements` | string | What to log for debugging |
| `error_user_message` | string | User-facing error messages |
| `error_on_failure` | string | How to handle failures |

### Tracking & Metadata Fields

| Field | Type | Description |
|-------|------|-------------|
| `created_by_id` | integer | User ID who created the task |
| `created_by_agent` | string | Agent that created the task (e.g., `ai_agent:claude-sonnet-4-5`) |
| `completed_at` | string | When task was completed (ISO 8601, null if not completed) |
| `completed_by_id` | integer | User ID who completed the task |
| `completed_by_agent` | string | Agent that completed the task |
| `completion_summary` | string | Summary of work done upon completion |
| `dependencies` | array | Array of task IDs that must be completed first |
| `claimed_at` | string | When task was claimed (ISO 8601, null if unclaimed) |
| `claim_expires_at` | string | When claim expires (ISO 8601, null if unclaimed) |
| `required_capabilities` | array | Required agent capabilities (e.g., `["code_generation", "testing"]`) |

### Estimation & Actuals Fields

| Field | Type | Description |
|-------|------|-------------|
| `actual_complexity` | string | Actual complexity after completion |
| `actual_files_changed` | integer | Actual number of files modified |
| `time_spent_minutes` | integer | Time spent on task in minutes |

### Review Fields

| Field | Type | Description |
|-------|------|-------------|
| `review_status` | string | Review decision: `approved`, `changes_requested`, `rejected` (null if not reviewed) |
| `review_notes` | string | Reviewer's notes and feedback |
| `reviewed_at` | string | When review was completed (ISO 8601) |
| `reviewed_by_id` | integer | User ID who reviewed the task |

### Timestamp Fields

| Field | Type | Description |
|-------|------|-------------|
| `inserted_at` | string | When task was created (ISO 8601) |
| `updated_at` | string | When task was last updated (ISO 8601) |

### Nested Object Structures

#### `key_files` Array

Each item in the `key_files` array has:

```json
{
  "file_path": "lib/path/to/file.ex",  // Relative path from project root
  "note": "Why this file is modified",  // Context for the change
  "position": 0                          // Order of modification (0-indexed)
}
```

#### `verification_steps` Array

Each item in the `verification_steps` array has:

```json
{
  "step_type": "command",                     // Type: "command", "manual", "test"
  "step_text": "mix test path/to/test.exs",  // The command or instruction
  "expected_result": "All tests pass",        // What success looks like
  "position": 0                               // Order of execution (0-indexed)
}
```

## Example Usage

### Get all tasks

```bash
curl -X GET \
  -H "Authorization: Bearer stride_dev_abc123..." \
  https://www.stridelikeaboss.com/api/tasks
```

### Get tasks in a specific column

```bash
curl -X GET \
  -H "Authorization: Bearer stride_dev_abc123..." \
  https://www.stridelikeaboss.com/api/tasks?column_id=5
```

## Use Cases

- Get overview of all tasks on the board
- Filter tasks by column (e.g., see all tasks in Ready)
- Find tasks by status or priority (filter client-side)
- Build dashboards or reports
- Monitor task progress

## Typical Column IDs

Column IDs vary by board, but typical columns are:

- Backlog - Unprioritized tasks
- Ready - Prioritized and ready to claim
- Doing - Currently being worked on
- Review - Completed and awaiting review
- Done - Fully completed tasks

Use the web UI or inspect responses to find column IDs for your board.

## Notes

- Returns all tasks across all columns if no `column_id` is provided
- Tasks are returned in no particular order (sort client-side as needed)
- Includes both regular tasks and goals
- Each task includes its parent goal information if it's a child task
- The `dependencies` array shows which tasks must be completed first

## Filtering and Sorting

The API doesn't support server-side filtering or sorting beyond column. To filter or sort:

1. Fetch all tasks (or tasks in specific column)
2. Filter client-side by:
   - Status (`open`, `in_progress`, `review`, `completed`)
   - Priority (`low`, `medium`, `high`, `critical`)
   - Type (`task`, `goal`)
   - Assignment (`assigned_to_id` null or not)
   - Required capabilities
3. Sort client-side by:
   - Priority (critical → low)
   - Creation date (`inserted_at`)
   - Complexity
   - Identifier

## Example Client-Side Filtering

```javascript
// Get all tasks
const response = await fetch('/api/tasks', {
  headers: {'Authorization': 'Bearer stride_dev_abc123...'}
});
const {data: tasks} = await response.json();

// Filter for high priority unassigned tasks
const availableTasks = tasks.filter(t =>
  t.priority === 'high' &&
  t.assigned_to_id === null &&
  t.status === 'open'
);

// Sort by priority then date
availableTasks.sort((a, b) => {
  const priorityOrder = {critical: 0, high: 1, medium: 2, low: 3};
  if (priorityOrder[a.priority] !== priorityOrder[b.priority]) {
    return priorityOrder[a.priority] - priorityOrder[b.priority];
  }
  return new Date(a.inserted_at) - new Date(b.inserted_at);
});
```

## See Also

- [GET /api/tasks/next](get_tasks_next.md) - Get next available task (pre-filtered by capabilities)
- [GET /api/tasks/:id](get_tasks_id.md) - Get specific task details
- [POST /api/tasks/claim](post_tasks_claim.md) - Claim a task to start working
