# GET /api/tasks/:id

Get details of a specific task by ID or identifier.

## Authentication

Requires a valid API token in the Authorization header:

```bash
Authorization: Bearer <your_api_token>
```

## Request

**Method:** GET
**Endpoint:** `/api/tasks/:id`

### URL Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | string | Yes | Task ID (numeric) or task identifier (e.g., "W21") |

## Response

### Success (200 OK)

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
    "created_by_id": 1,
    "created_by_agent": null,
    "assigned_to_id": 5,
    "assigned_to_name": "Agent User",
    "completed_by_agent": null,
    "time_spent_minutes": null,
    "completion_notes": null,
    "review_status": null,
    "review_report": null,
    "parent_goal_id": 120,
    "parent_goal_identifier": "G10",
    "parent_goal_title": "User Management System",
    "required_capabilities": ["code_generation"],
    "dependencies": [119],
    "inserted_at": "2025-12-28T10:00:00Z",
    "updated_at": "2025-12-28T11:00:00Z",
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

### Not Found (404)

Task not found:

```json
{
  "error": "Task not found"
}
```

## Field Descriptions

| Field | Type | Description |
|-------|------|-------------|
| `id` | integer | Unique task ID |
| `identifier` | string | Human-readable identifier (W21, G10, etc.) |
| `title` | string | Task title |
| `description` | string | Detailed description |
| `status` | string | Current status: `open`, `in_progress`, `blocked`, `review`, `completed` |
| `priority` | string | Priority: `low`, `medium`, `high`, `critical` |
| `complexity` | string | Complexity: `trivial`, `low`, `medium`, `high`, `very_high` |
| `needs_review` | boolean | Whether task requires human review before completion |
| `type` | string | Type: `task` or `goal` |
| `column_id` | integer | Current column ID |
| `column_name` | string | Current column name |
| `board_id` | integer | Board ID |
| `board_name` | string | Board name |
| `created_by_id` | integer | User ID who created the task |
| `created_by_agent` | string | Agent that created the task (e.g., "ai_agent:claude-sonnet-4-5") |
| `assigned_to_id` | integer | User ID assigned to the task (null if unclaimed) |
| `assigned_to_name` | string | Name of assigned user |
| `completed_by_agent` | string | Agent that completed the task |
| `time_spent_minutes` | integer | Time spent on task in minutes |
| `completion_notes` | string | Notes provided when completing the task |
| `review_status` | string | Review decision: `approved`, `changes_requested`, `rejected` (null if not reviewed) |
| `review_report` | string | Structured review report from task-reviewer agent (null if not provided) |
| `parent_goal_id` | integer | ID of parent goal (null if no parent) |
| `parent_goal_identifier` | string | Identifier of parent goal |
| `parent_goal_title` | string | Title of parent goal |
| `required_capabilities` | array | Required agent capabilities to work on this task |
| `dependencies` | array | Array of task IDs that must be completed before this task |
| `inserted_at` | string | When task was created (ISO 8601) |
| `updated_at` | string | When task was last updated (ISO 8601) |
| `completed_at` | string | When task was completed (null if not completed) |

## Fields Projection (W2076/W2094)

`GET /api/tasks/:id?fields=<comma-separated names>` returns only the named
fields instead of the full body. The contract:

- **Allow-list.** Only the summary and review/completion field names are
  projectable — these 27 names (source of truth:
  `KanbanWeb.API.TaskJSON.projectable_field_names/0`):
  `id`, `identifier`, `title`, `type`, `status`, `priority`, `complexity`,
  `dependencies`, `created_by_agent`, `parent_id`, `claim_expires_at`,
  `needs_review`, `review_status`, `review_notes`, `review_report`,
  `workflow_steps`, `explorer_result`, `reviewer_result`, `reviewed_at`,
  `reviewed_by_id`, `completed_at`, `completed_by_id`, `completed_by_agent`,
  `completion_summary`, `completion_notes`, `actual_complexity`,
  `actual_files_changed`.
  Naming anything else rejects the WHOLE request with a 422
  (`"task fields rejected"`); no partial projection is returned.
- **`id` and `identifier` are always included**, even when not requested, so
  responses stay self-describing. `fields=status` returns `id`, `identifier`,
  and `status`.
- **One scalar string only (W2094).** Array or map shapes — `fields[]=x`,
  `fields[key]=x` — are rejected with a 422 rather than silently serving the
  full body, so a client-side encoding bug never yields maximum data.
- **Repeated `fields` params last-win (W2094).** `?fields=title&fields=status`
  keeps only `status` (standard Plug semantics); the earlier value is dropped
  with no signal. Send one comma-separated string.
- **The unknown-name echo is capped at 10 (W2094).** A 422 lists at most the
  first 10 unknown names plus a final entry carrying the total count, bounding
  reflected amplification.
- **Whitespace trimming is Unicode-wide (W2094).** Names are split on commas
  and trimmed with `String.trim/1`, which strips any Unicode whitespace (NBSP
  and tab included) — relevant if clients generate names programmatically.
- **Mutually exclusive with `response_view`.** Sending both parameters on one
  request — whatever their values — is a 422; each works alone.

### Rejected (422)

```json
{
  "error": "task fields rejected",
  "documentation": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/get_tasks_id.md",
  "failures": [
    {
      "field": "fields",
      "errors": [
        {"field": "column_id", "message": "column_id is not in the allow-listed fields for GET /api/tasks/:id"}
      ]
    }
  ],
  "common_causes": ["..."]
}
```

## Example Usage

### Get task by numeric ID

```bash
curl -X GET \
  -H "Authorization: Bearer stride_dev_abc123..." \
  https://www.stridelikeaboss.com/api/tasks/123
```

### Get task by identifier

```bash
curl -X GET \
  -H "Authorization: Bearer stride_dev_abc123..." \
  https://www.stridelikeaboss.com/api/tasks/W21
```

## Use Cases

- Check current task status and assigned user
- Verify task is ready to claim (not blocked by dependencies)
- View task details before claiming
- Check review status after submitting for review
- Get parent goal information for child tasks
- View completion notes and time spent

## Notes

- You can use either numeric ID or identifier (W21, G10, etc.)
- Task must belong to the board associated with your API token
- The `dependencies` array contains task IDs that must be completed first
- Review status is only set after a human reviewer makes a decision
- Goals (type=goal) are parent tasks that contain child tasks

## See Also

- [GET /api/tasks](get_tasks.md) - List all tasks
- [GET /api/tasks/:id/tree](get_tasks_id_tree.md) - Get task with all children (for goals)
- [POST /api/tasks/claim](post_tasks_claim.md) - Claim this task
