# GET /api/tasks

List the tasks on the board. By default every non-archived task is returned in
one response; opt-in [cursor pagination and filters](#pagination-and-filters)
narrow the result to one page and, optionally, to tasks matching a status, type,
priority, assignee, parent goal or update time.

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
| `column_id` | integer | No | Filter tasks by column ID. If omitted, returns all tasks from all columns. Combines with every filter below. |
| `response_view` | string | No | `slim` returns a compact summary row per task instead of the full object. Any other value — including `full`, an unrecognised string, or the parameter being absent — returns the unchanged full response. Works in both modes. |
| `limit` | integer | No | **Paginated mode.** Page size, `1`–`200`. Default `50`. |
| `cursor` | string | No | **Paginated mode.** Opaque cursor from a previous page's `meta.next_cursor`. Omit for the first page. |
| `status` | string | No | **Paginated mode.** One of `open`, `in_progress`, `completed`, `blocked`. |
| `type` | string | No | **Paginated mode.** One of `work`, `defect`, `goal`. |
| `priority` | string | No | **Paginated mode.** One of `low`, `medium`, `high`, `critical`. |
| `assigned_to_id` | integer | No | **Paginated mode.** Only tasks assigned to this user ID. |
| `parent` | string | No | **Paginated mode.** A goal identifier on this board, such as `G12`. Returns that goal's child tasks. |
| `updated_since` | string | No | **Paginated mode.** ISO 8601 datetime, such as `2026-01-31T12:00:00Z`. Returns only tasks whose `updated_at` is at or after it. |

The parameters marked **Paginated mode** are opt-in: when **none** of them is
present the endpoint returns the unpaginated response described next, exactly
as it always has. When **any** of them is present — even with an empty value —
the response is paginated and carries a `meta` block. See
[Pagination and filters](#pagination-and-filters).

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
      "type": "work",
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
      "review_report": null,
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
      "type": "work",
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

## Selecting the response view

| Parameter | Values | Default | Effect |
|---|---|---|---|
| `response_view` | `slim` | absent (full) | `slim` returns a compact summary row per task instead of the full object. Any other value — including `full`, an unrecognised string, or the parameter being absent — returns the unchanged full response. |

Only the exact lowercase string `slim` opts in.

**Why you would want it.** A board-wide list of full task objects is the
largest response this API produces, and almost none of its content is read when
the caller is listing rather than reading. Fetch the compact rows to find the
task you want, then [GET /api/tasks/:id](get_tasks_id.md) for its detail —
that endpoint is always full-fidelity and is unaffected by `response_view`.

**What never changes.** `response_view` changes only the shape of each row, not
which rows are returned: the board scoping and the underlying query are
identical under both views, so the slim view can only narrow a row, never widen
it or surface a task the full view withheld. The summary keys are a strict
subset of the full row's. The 400 and 403 responses are identical under both
views, because the view is applied only at render.

### Success (200 OK) — `?response_view=slim`

Each row carries exactly these eleven keys:

```json
{
  "data": [
    {
      "id": 123,
      "identifier": "W21",
      "title": "Implement authentication",
      "type": "work",
      "status": "in_progress",
      "priority": "high",
      "complexity": "medium",
      "parent_id": null,
      "dependencies": [],
      "claim_expires_at": "2025-12-28T11:30:00Z",
      "created_by_agent": "ai_agent:claude-sonnet-4-5"
    }
  ]
}
```

`dependencies` renders as `[]` rather than `null` when unset, matching the same
summary shape returned by
[GET /api/tasks/:id/dependencies](get_tasks_id_dependencies.md) and
[GET /api/tasks/:id/dependents](get_tasks_id_dependents.md).

## Pagination and filters

**Opt-in.** Sending any of `limit`, `cursor`, `status`, `type`, `priority`,
`assigned_to_id`, `parent` or `updated_since` switches the endpoint into
paginated mode. `column_id` and `response_view` on their own do **not** — they
keep the unpaginated response, which is unchanged: no `meta` key, same rows,
same order. A page key sent with an empty value (`?limit=`) still opts in, and
is then rejected with a `400` rather than silently ignored.

**How paging works.**

- Pages are ordered by task `id` ascending. (The unpaginated response is
  ordered by column position, then task position.)
- Each page carries `meta.next_cursor`. Pass it back as `cursor` to get the next
  page; keep the same filters. When `meta.next_cursor` is `null` you have the
  last page.
- The cursor is opaque — do not build or parse it. It is keyset-based, so a task
  created while you are paging never causes a row to be skipped or returned
  twice; it simply appears on a later page.
- Archived tasks are excluded, as in the unpaginated response.

**How filters combine.** Every filter you send is applied together (AND), and
they also combine with `column_id`:

- `status`, `type` and `priority` take exactly one value each (no comma lists),
  matched case-sensitively against the values in the parameter table.
- `assigned_to_id` matches the task's assignee.
- `parent` takes a goal identifier on **this** board (identifiers are numbered
  per board). An identifier that is unknown, or that names a task that is not
  a goal, returns an empty `data` list — not an error.
- `updated_since` is inclusive. A value with an offset (`Z`, `+02:00`) is
  converted to UTC; a value with no offset is read as UTC. `updated_at` is
  stored to the whole second, so the comparison is made at whole-second
  precision: any fractional part of the bound is dropped (`12:00:00.5Z`
  behaves as `12:00:00Z`). Every task updated during that second is therefore
  returned — including one updated a moment *before* `.5` — so a sync never
  misses an update, at the cost of occasionally returning a task you already
  have. Treat results as upserts. A bare date such as `2026-01-31` is
  rejected — include a time.

**Board scoping.** Every page is scoped to the token's board. A cursor, a
`parent` identifier or a `column_id` taken from another board can never return
that board's tasks.

**Incremental sync.** To fetch only what changed since your last poll, send
`updated_since` with the time of that poll, plus a `limit`, and follow
`meta.next_cursor` until it is `null`. Expect a task updated in the same
second as that time to come back again, and apply rows as upserts.

### Success (200 OK) — paginated

```bash
curl -H "Authorization: Bearer <your_api_token>" \
  "https://www.stridelikeaboss.com/api/tasks?limit=2&status=open"
```

```json
{
  "data": [
    {
      "id": 123,
      "identifier": "W21",
      "title": "Implement authentication",
      "status": "open",
      "...": "every other field of the full task object, as above"
    },
    {
      "id": 130,
      "identifier": "W24",
      "title": "Add rate limiting",
      "status": "open",
      "...": "every other field of the full task object, as above"
    }
  ],
  "meta": {
    "next_cursor": "MTMw",
    "limit": 2
  }
}
```

The next page is `?limit=2&status=open&cursor=MTMw`. On the last page
`next_cursor` is `null`:

```json
{
  "data": [ { "id": 131, "identifier": "W25", "...": "..." } ],
  "meta": { "next_cursor": null, "limit": 2 }
}
```

With `response_view=slim` each row is the compact summary row shown above, and
the `meta` block is identical:

```json
{
  "data": [
    {
      "id": 123,
      "identifier": "W21",
      "title": "Implement authentication",
      "type": "work",
      "status": "open",
      "priority": "high",
      "complexity": "medium",
      "parent_id": null,
      "dependencies": [],
      "claim_expires_at": null,
      "created_by_agent": "ai_agent:claude-sonnet-4-5"
    }
  ],
  "meta": { "next_cursor": "MTIz", "limit": 1 }
}
```

### `meta` fields (paginated mode only)

| Field | Type | Description |
|-------|------|-------------|
| `meta.next_cursor` | string or null | Cursor for the next page. `null` when this is the last page. |
| `meta.limit` | integer | The page size applied to this request (`50` when `limit` was not sent). |

### Bad Request (400)

Every paginated-mode parameter is validated before any data is read. An invalid
value returns `400` with an `error` message naming the parameter, plus
`documentation` and `getting_started` links. The first invalid parameter is
reported, checked in the order `limit`, `cursor`, `status`, `type`, `priority`,
`assigned_to_id`, `parent`, `updated_since`, then `column_id`:

| Cause | `error` |
|---|---|
| `limit` is empty, not an integer, below 1 or above 200 | `Invalid limit: must be an integer between 1 and 200` |
| `cursor` is not one this API issued | `Invalid cursor: use the meta.next_cursor value from a previous page` |
| `status` is not one of the listed values | `Invalid status: must be one of open, in_progress, completed, blocked` |
| `type` is not one of the listed values | `Invalid type: must be one of work, defect, goal` |
| `priority` is not one of the listed values | `Invalid priority: must be one of low, medium, high, critical` |
| `assigned_to_id` is not a positive integer | `Invalid assigned_to_id: must be a positive integer` |
| `parent` is empty or longer than 255 bytes (UTF-8) | `Invalid parent: must be a goal identifier such as G12` |
| `updated_since` is not an ISO 8601 datetime (including a bare date) | `Invalid updated_since: must be an ISO 8601 datetime such as 2026-01-31T12:00:00Z` |
| `column_id` is not an integer (both modes) | `Invalid column_id: must be an integer` |

```json
{
  "error": "Invalid limit: must be an integer between 1 and 200",
  "documentation": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/README.md",
  "getting_started": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/GETTING-STARTED-WITH-AI.md"
}
```

Array or map shapes such as `limit[]=5` are rejected the same way.

### Not Found (404)

`column_id` names a column that does not exist or belongs to another board. The
two cases are deliberately indistinguishable, in both modes:

```json
{
  "error": "Task not found"
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
| `status` | string | Current status: `open`, `in_progress`, `completed`, `blocked` |
| `priority` | string | Priority level: `low`, `medium`, `high`, `critical` |
| `complexity` | string | Estimated complexity: `small`, `medium`, `large` |
| `needs_review` | boolean | Whether task requires human review before completion |
| `type` | string | Type: `work`, `defect` or `goal` |
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
| `review_report` | string | Structured review report from task-reviewer agent (null if not provided) |
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

### Page through open high-priority work, 50 at a time

```bash
curl -X GET \
  -H "Authorization: Bearer stride_dev_abc123..." \
  "https://www.stridelikeaboss.com/api/tasks?status=open&priority=high&type=work&limit=50"
# then repeat with &cursor=<meta.next_cursor> until next_cursor is null
```

### Fetch only tasks changed since the last sync

```bash
curl -X GET \
  -H "Authorization: Bearer stride_dev_abc123..." \
  "https://www.stridelikeaboss.com/api/tasks?updated_since=2026-01-31T12:00:00Z&limit=100&response_view=slim"
```

### List a goal's child tasks

```bash
curl -X GET \
  -H "Authorization: Bearer stride_dev_abc123..." \
  "https://www.stridelikeaboss.com/api/tasks?parent=G12&limit=200"
```

## Use Cases

- Get overview of all tasks on the board
- Filter tasks by column (e.g., see all tasks in Ready)
- Find tasks by status, type, priority, assignee or parent goal (server-side filters)
- Sync incrementally with `updated_since` and cursor pagination
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
- Without page keys, tasks are ordered by column position then task position; in paginated mode, by `id` ascending
- Includes both regular tasks and goals
- Each task includes its parent goal information if it's a child task
- The `dependencies` array shows which tasks must be completed first

## Filtering and Sorting

Server-side filters cover `column_id`, `status`, `type`, `priority`,
`assigned_to_id`, `parent` and `updated_since` — see
[Pagination and filters](#pagination-and-filters). Prefer them on large boards:
the unpaginated response returns every task on the board in one body.

The API does not sort beyond the fixed orders described above, and some
criteria have no server-side filter (for example "unassigned" or required
capabilities). For those:

1. Fetch the tasks (narrowed with server-side filters where you can)
2. Filter client-side by:
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
