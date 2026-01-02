# PATCH /api/tasks/:id

Update an existing task. This endpoint allows you to modify any task field including title, description, priority, status, assigned user, and all planning fields.

## Authentication

Requires a valid API token in the Authorization header:

```bash
Authorization: Bearer <your_api_token>
```

## Request

**Method:** PATCH
**Endpoint:** `/api/tasks/:id`
**Content-Type:** application/json

### URL Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | string | Yes | Task ID (numeric) or task identifier (e.g., "W21") |

### Request Body Parameters

All parameters are optional. Only include the fields you want to update.

#### Basic Fields

| Parameter | Type | Description |
|-----------|------|-------------|
| `title` | string | Task title |
| `description` | string | Detailed task description |
| `acceptance_criteria` | string | Acceptance criteria for task completion |
| `type` | string | Task type: `work`, `defect`, or `goal` |
| `priority` | string | Priority: `low`, `medium`, `high`, `critical` |
| `status` | string | Status: `open`, `in_progress`, `completed`, `blocked` |
| `needs_review` | boolean | Whether task requires human review before completion |
| `assigned_to_id` | integer | ID of user to assign the task to (null to unassign) |
| `parent_id` | integer | ID of parent goal task |
| `column_id` | integer | ID of column to move task to |

#### Planning & Context Fields

| Parameter | Type | Description |
|-----------|------|-------------|
| `complexity` | string | Estimated complexity: `small`, `medium`, `large` |
| `estimated_files` | string | Estimated number of files (e.g., "3-5") |
| `why` | string | Why - problem/rationale for the task |
| `what` | string | What - implementation approach |
| `where_context` | string | Where - code location/context |

#### Implementation Guidance Fields

| Parameter | Type | Description |
|-----------|------|-------------|
| `patterns_to_follow` | string | Code patterns to follow |
| `database_changes` | string | Database/schema changes needed |
| `validation_rules` | string | Validation rules to implement |

#### Observability Fields

| Parameter | Type | Description |
|-----------|------|-------------|
| `telemetry_event` | string | Telemetry event name (e.g., "[:kanban, :domain, :action]") |
| `metrics_to_track` | string | Metrics to track |
| `logging_requirements` | string | Logging requirements |

#### Error Handling Fields

| Parameter | Type | Description |
|-----------|------|-------------|
| `error_user_message` | string | User-facing error message |
| `error_on_failure` | string | What happens on failure |

#### Collections (Arrays)

| Parameter | Type | Description |
|-----------|------|-------------|
| `dependencies` | array of strings | Task identifiers that must be completed first (e.g., ["W15", "W16"]) |
| `technology_requirements` | array of strings | Required technologies/libraries |
| `pitfalls` | array of strings | Common pitfalls to avoid |
| `out_of_scope` | array of strings | Items explicitly out of scope |
| `security_considerations` | array of strings | Security considerations |
| `required_capabilities` | array of strings | Required agent capabilities |

#### Embedded Collections

| Parameter | Type | Description |
|-----------|------|-------------|
| `key_files` | array of objects | Key files to read first. Each object has `file_path`, `note`, and `position` |
| `verification_steps` | array of objects | Verification steps. Each object has `step_type`, `step_text`, `expected_result`, and `position` |

#### Maps/Objects

| Parameter | Type | Description |
|-----------|------|-------------|
| `testing_strategy` | object | Testing strategy (JSON object) with optional keys: `unit_tests`, `integration_tests`, `property_tests`, `coverage_target`, `test_data`, `mocking`, `edge_cases`, `performance_tests`, `manual_tests`, `regression_tests`, `security_tests`. See [POST /api/tasks](post_tasks.md#testing-strategy-format) for format details. |
| `integration_points` | object | Integration points (JSON object) with optional keys: `telemetry_events`, `pubsub_broadcasts`, `phoenix_channels`, `external_apis`. Each value should be an array of strings. |

#### Completion Tracking

| Parameter | Type | Description |
|-----------|------|-------------|
| `completion_summary` | string | Summary of work completed |
| `time_spent_minutes` | integer | Time spent on task in minutes |
| `actual_complexity` | string | Actual complexity: `small`, `medium`, `large` |
| `actual_files_changed` | string | Actual number of files changed |

#### Review Queue

| Parameter | Type | Description |
|-----------|------|-------------|
| `review_status` | string | Review status: `pending`, `approved`, `changes_requested`, `rejected` |
| `review_notes` | string | Notes from reviewer |

### Request Body Example

#### Update basic fields

```json
{
  "task": {
    "title": "Implement JWT authentication",
    "description": "Add JWT token-based authentication to the API endpoints",
    "priority": "high",
    "needs_review": true
  }
}
```

#### Update with planning context

```json
{
  "task": {
    "title": "Implement user registration",
    "complexity": "medium",
    "estimated_files": "4-6",
    "why": "Users need to create accounts to access the platform",
    "what": "Create registration form, API endpoint, and email verification flow",
    "where_context": "lib/kanban_web/controllers/auth/, lib/kanban/accounts/",
    "dependencies": ["W15"],
    "technology_requirements": ["bcrypt", "swoosh"],
    "key_files": [
      {
        "file_path": "lib/kanban/accounts/user.ex",
        "note": "User schema and validation",
        "position": 0
      },
      {
        "file_path": "lib/kanban/accounts.ex",
        "note": "Account context functions",
        "position": 1
      }
    ]
  }
}
```

#### Assign task to user

```json
{
  "task": {
    "assigned_to_id": 5,
    "status": "in_progress"
  }
}
```

#### Update completion metrics

```json
{
  "task": {
    "actual_complexity": "large",
    "actual_files_changed": "8",
    "time_spent_minutes": 120,
    "completion_summary": "Implemented authentication with JWT tokens and refresh token flow"
  }
}
```

## Response

### Success (200 OK)

Returns the updated task with all fields:

```json
{
  "data": {
    "id": 123,
    "identifier": "W21",
    "title": "Implement JWT authentication",
    "description": "Add JWT token-based authentication to the API endpoints",
    "acceptance_criteria": "Users can login, logout, and refresh tokens",
    "status": "in_progress",
    "priority": "high",
    "complexity": "medium",
    "needs_review": true,
    "type": "work",
    "column_id": 6,
    "column_name": "Doing",
    "board_id": 1,
    "board_name": "Main Board",
    "created_by_id": 1,
    "created_by_agent": null,
    "assigned_to_id": 5,
    "assigned_to_name": "Agent User",
    "parent_goal_id": null,
    "parent_goal_identifier": null,
    "parent_goal_title": null,
    "why": "Users need secure authentication",
    "what": "JWT-based auth with refresh tokens",
    "where_context": "lib/kanban_web/controllers/auth/",
    "dependencies": ["W15"],
    "technology_requirements": ["joken", "bcrypt"],
    "required_capabilities": ["code_generation"],
    "time_spent_minutes": null,
    "completion_summary": null,
    "actual_complexity": null,
    "actual_files_changed": null,
    "review_status": null,
    "review_notes": null,
    "inserted_at": "2025-12-28T10:00:00Z",
    "updated_at": "2025-12-28T11:30:00Z",
    "completed_at": null
  }
}
```

### Forbidden (403)

Task doesn't belong to the current board:

```json
{
  "error": "Task does not belong to this board"
}
```

### Unprocessable Entity (422)

Validation errors:

```json
{
  "errors": {
    "title": ["can't be blank"],
    "priority": ["is invalid"]
  }
}
```

### Not Found (404)

Task not found:

```json
{
  "error": "Task not found"
}
```

## Behavior Notes

### Priority Changes
When `priority` is updated, a task history record is automatically created tracking the change from old to new priority.

### Assignment Changes
When `assigned_to_id` is updated, a task history record is automatically created tracking the assignment change.

### Dependency Updates
When `dependencies` array is updated:
- The task's blocking status is automatically recalculated
- If all dependencies are completed, task status changes from `blocked` to `open`
- If task has incomplete dependencies, status changes to `blocked`
- Dependent tasks cannot be deleted while they are listed as dependencies

### Column Changes
When moving a task to a different column via `column_id`:
- The task's position is automatically set
- A task history record is created
- Changes are broadcast to all connected clients viewing the board

## Example Usage

### Update task title and priority

```bash
curl -X PATCH \
  -H "Authorization: Bearer stride_dev_abc123..." \
  -H "Content-Type: application/json" \
  -d '{
    "task": {
      "title": "Implement JWT authentication",
      "priority": "critical"
    }
  }' \
  https://www.stridelikeaboss.com/api/tasks/W21
```

### Assign task to user

```bash
curl -X PATCH \
  -H "Authorization: Bearer stride_dev_abc123..." \
  -H "Content-Type: application/json" \
  -d '{
    "task": {
      "assigned_to_id": 5,
      "status": "in_progress"
    }
  }' \
  https://www.stridelikeaboss.com/api/tasks/123
```

### Add dependencies

```bash
curl -X PATCH \
  -H "Authorization: Bearer stride_dev_abc123..." \
  -H "Content-Type: application/json" \
  -d '{
    "task": {
      "dependencies": ["W15", "W16"]
    }
  }' \
  https://www.stridelikeaboss.com/api/tasks/W21
```

### Update planning context

```bash
curl -X PATCH \
  -H "Authorization: Bearer stride_dev_abc123..." \
  -H "Content-Type: application/json" \
  -d '{
    "task": {
      "complexity": "large",
      "why": "Users need secure authentication to access protected resources",
      "what": "Implement JWT-based authentication with access and refresh tokens",
      "where_context": "lib/kanban_web/controllers/auth/, lib/kanban/accounts/"
    }
  }' \
  https://www.stridelikeaboss.com/api/tasks/W21
```

## Use Cases

- **Update task details**: Modify title, description, or acceptance criteria
- **Change priority**: Adjust task priority based on business needs
- **Assign/reassign**: Assign task to a user or reassign to someone else
- **Add planning context**: Add implementation guidance and context for AI agents
- **Track dependencies**: Define which tasks must be completed first
- **Update completion metrics**: Record actual complexity and time spent
- **Move between columns**: Change task workflow state
- **Add technical details**: Specify technology requirements, patterns, security considerations

## Workflow Integration

This endpoint is commonly used in these workflows:

1. **Task refinement**: Add detailed planning context before starting work
2. **Priority adjustments**: Respond to changing business priorities
3. **Dependency management**: Update task dependencies as project evolves
4. **Progress tracking**: Update status and metrics as work progresses
5. **Review feedback**: Update tasks based on review notes

## Notes

- You can update any combination of fields in a single request
- Only include fields you want to change in the request body
- Task must belong to the board associated with your API token
- Changing `assigned_to_id` creates a task history entry
- Changing `priority` creates a task history entry
- Changing `dependencies` automatically updates blocking status
- Use numeric ID or identifier (W21, G10, etc.) in the URL
- Empty arrays (`[]`) will clear existing array values
- Setting a field to `null` will clear that field's value
- This endpoint does NOT trigger workflow hooks (use specific endpoints like `/complete` for that)

## See Also

- [GET /api/tasks/:id](get_tasks_id.md) - Get task details
- [POST /api/tasks](post_tasks.md) - Create a new task
- [PATCH /api/tasks/:id/complete](patch_tasks_id_complete.md) - Complete a task (triggers hooks)
- [POST /api/tasks/claim](post_tasks_claim.md) - Claim a task
- [GET /api/tasks](get_tasks.md) - List all tasks
