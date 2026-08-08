# GET /api/tasks/:id/tree

Get a task (usually a goal) with all its child tasks in a hierarchical tree structure.

## Authentication

Requires a valid API token in the Authorization header:

```bash
Authorization: Bearer <your_api_token>
```

## Request

**Method:** GET
**Endpoint:** `/api/tasks/:id/tree`

### URL Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | string | Yes | Task ID (numeric) or task identifier (e.g., "G10") |

### Query Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `response_view` | string | No | `slim` renders each entry in `children` as a compact summary row. Any other value — including `full`, an unrecognised string, or the parameter being absent — returns the unchanged full response. |

Under `slim` the root `task` keeps its **full** render, and `counts` is
unchanged. The caller asked for that specific task and reads its planning
fields — `why`, `what`, `acceptance_criteria`, `key_files` — alongside its
children; only the children are navigational. See
[Selecting the response view](#selecting-the-response-view) below.

## Response

### Success (200 OK)

Returns the task together with its child tasks and a counts summary:

```json
{
  "data": {
    "task": {
      "id": 125,
      "identifier": "G10",
      "title": "Implement user authentication system",
      "description": "Complete authentication system with JWT tokens",
      "status": "in_progress",
      "priority": "critical",
      "complexity": "very_high",
      "type": "goal",
      "column_id": 6,
      "column_name": "Doing",
      "board_id": 1,
      "created_by_id": 1,
      "created_by_agent": "ai_agent:claude-sonnet-4-5",
      "inserted_at": "2025-12-28T13:00:00Z",
      "updated_at": "2025-12-28T14:00:00Z"
    },
    "children": [
      {
        "id": 126,
        "identifier": "W23",
        "title": "Create database schema for users",
        "description": "Design and implement user table",
        "status": "completed",
        "priority": "critical",
        "complexity": "medium",
        "type": "task",
        "column_id": 8,
        "parent_id": 125,
        "dependencies": [],
        "completed_at": "2025-12-28T13:30:00Z"
      },
      {
        "id": 127,
        "identifier": "W24",
        "title": "Implement JWT token generation",
        "description": "Create functions to generate and validate JWT tokens",
        "status": "in_progress",
        "priority": "critical",
        "complexity": "medium",
        "type": "task",
        "column_id": 6,
        "parent_id": 125,
        "assigned_to_id": 5,
        "dependencies": ["W23"]
      },
      {
        "id": 128,
        "identifier": "W25",
        "title": "Write authentication tests",
        "description": "Comprehensive test suite for auth system",
        "status": "blocked",
        "priority": "high",
        "complexity": "medium",
        "type": "task",
        "column_id": 5,
        "parent_id": 125,
        "dependencies": ["W24"]
      }
    ],
    "counts": {
      "total": 3,
      "completed": 1,
      "blocked": 1
    }
  }
}
```

`children` is a **flat** array of full task objects (each abbreviated above —
the real render carries every field `data/1` returns). It is not recursive:
children do not carry their own `children` key. `counts` summarises the
children, and callers aggregate on it.

## Selecting the response view

| Parameter | Values | Default | Effect |
|---|---|---|---|
| `response_view` | `slim` | absent (full) | `slim` renders each `children` entry as a compact summary row. The root `task` and `counts` are unchanged. Any other value — including `full`, an unrecognised string, or the parameter being absent — returns the unchanged full response. |

Only the exact lowercase string `slim` opts in.

**Why you would want it.** A goal's children are read to navigate — to see what
exists, what is blocked, and what to claim next — not to read each child's
planning detail. The full render returns every field of every child, which for
a large goal is most of the response for none of the reason it was requested.

**What never changes.** The root `task` keeps its full render in both views,
and the `counts` object is passed through untouched — callers aggregate on it.
`response_view` changes only what is rendered: it never changes which tasks are
returned, what is stored, or the authorization required. The board scoping and
the 403/404 responses are identical under both views, because the view is
selected only after the lookup succeeds.

### Success (200 OK) — `?response_view=slim`

Each `children` entry carries exactly these eight keys:

```json
{
  "data": {
    "task": { "...": "the full task render, unchanged" },
    "children": [
      {
        "id": 126,
        "identifier": "W23",
        "title": "Create database schema for users",
        "status": "completed",
        "priority": "critical",
        "complexity": "medium",
        "dependencies": [],
        "created_by_agent": "ai_agent:claude-sonnet-4-5"
      }
    ],
    "counts": { "total": 3, "completed": 1, "blocked": 1 }
  }
}
```

`dependencies` renders as `[]` rather than `null` when unset, matching the same
summary shape returned by
[GET /api/tasks/:id/dependencies](get_tasks_id_dependencies.md) and
[GET /api/tasks/:id/dependents](get_tasks_id_dependents.md).

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

## Example Usage

### Get goal tree by ID

```bash
curl -X GET \
  -H "Authorization: Bearer stride_dev_abc123..." \
  https://www.stridelikeaboss.com/api/tasks/125/tree
```

### Get goal tree by identifier

```bash
curl -X GET \
  -H "Authorization: Bearer stride_dev_abc123..." \
  https://www.stridelikeaboss.com/api/tasks/G10/tree
```

## Use Cases

- View all child tasks of a goal
- Understand task dependencies within a goal
- Check progress on a multi-task goal
- Display hierarchical task structure
- Track which child tasks are completed/blocked/in-progress

## Response Structure

The response is a single parent with a flat list of its children:

```
{
  data: {
    task: {...},        // The parent task/goal, always fully rendered
    children: [{...}],  // Flat array of child tasks (empty if none)
    counts: {...}       // total / completed / blocked, summarising children
  }
}
```

- `task` - The task object with all its fields. Never slimmed.
- `children` - Array of child task objects (empty array if no children). Each
  entry is a task object directly — children do not nest further, and do not
  carry their own `children` key. Under `?response_view=slim` each entry is the
  compact summary row instead.
- `counts` - `total`, `completed` and `blocked` counts over the children.
  Identical under both views.

## Notes

- Works for both regular tasks and goals, but most useful for goals
- Regular tasks without children will have an empty `children` array
- `children` is one level deep — Stride's hierarchy is goal → task, so a child
  never carries children of its own
- Each child task includes its dependencies array
- Useful for understanding which tasks are blocked by others
- Goals typically move to Done only when all children are complete

## Visualizing the Tree

You can use the tree structure to visualize task progress:

```
G10: Implement user authentication system [In Progress]
├── W23: Create database schema [Done] ✓
├── W24: Implement JWT tokens [In Progress] (depends on W23)
└── W25: Write authentication tests [Blocked] (depends on W24)
```

## See Also

- [GET /api/tasks/:id](get_tasks_id.md) - Get single task details without children
- [POST /api/tasks](post_tasks.md) - Create goals with nested child tasks
- [GET /api/tasks/:id/dependencies](get_tasks_id_dependencies.md) - Get dependency tree (not yet documented)
