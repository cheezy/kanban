# GET /api/tasks/:id/dependencies

Get the complete dependency tree for a task, showing all tasks that must be completed before this task can begin. This endpoint recursively traverses all dependencies to show the full dependency chain.

## Authentication

Requires a valid API token in the Authorization header:

```bash
Authorization: Bearer <your_api_token>
```

## Request

**Method:** GET
**Endpoint:** `/api/tasks/:id/dependencies`

### URL Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | string | Yes | Task ID (numeric) or task identifier (e.g., "W21") |

## Response

### Success (200 OK)

Returns the task and its complete dependency tree with nested dependencies:

```json
{
  "task": {
    "id": 125,
    "identifier": "W25",
    "title": "Deploy authentication to production",
    "status": "blocked",
    "priority": "high",
    "complexity": "small",
    "dependencies": ["W21", "W23"]
  },
  "dependencies": [
    {
      "task": {
        "id": 121,
        "identifier": "W21",
        "title": "Implement JWT authentication",
        "status": "completed",
        "priority": "high",
        "complexity": "medium",
        "dependencies": ["W15"]
      },
      "dependencies": [
        {
          "task": {
            "id": 115,
            "identifier": "W15",
            "title": "Create user database schema",
            "status": "completed",
            "priority": "high",
            "complexity": "small",
            "dependencies": []
          },
          "dependencies": []
        }
      ]
    },
    {
      "task": {
        "id": 123,
        "identifier": "W23",
        "title": "Write authentication tests",
        "status": "in_progress",
        "priority": "medium",
        "complexity": "medium",
        "dependencies": ["W21"]
      },
      "dependencies": [
        {
          "task": {
            "id": 121,
            "identifier": "W21",
            "title": "Implement JWT authentication",
            "status": "completed",
            "priority": "high",
            "complexity": "medium",
            "dependencies": ["W15"]
          },
          "dependencies": [
            {
              "task": {
                "id": 115,
                "identifier": "W15",
                "title": "Create user database schema",
                "status": "completed",
                "priority": "high",
                "complexity": "small",
                "dependencies": []
              },
              "dependencies": []
            }
          ]
        }
      ]
    }
  ]
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

## Response Structure

The response contains:

### Task Summary Fields

Each task object includes:

| Field | Type | Description |
|-------|------|-------------|
| `id` | integer | Task ID |
| `identifier` | string | Human-readable identifier (W21, G10, etc.) |
| `title` | string | Task title |
| `status` | string | Current status: `open`, `in_progress`, `completed`, `blocked` |
| `priority` | string | Priority: `low`, `medium`, `high`, `critical` |
| `complexity` | string | Complexity: `small`, `medium`, `large` |
| `dependencies` | array | Array of task identifiers this task depends on |

### Dependency Tree Structure

- **task**: The root task being queried
- **dependencies**: Array of dependency objects, each containing:
  - **task**: A task that the root task depends on
  - **dependencies**: Recursive array of that task's dependencies

## Understanding the Dependency Tree

The dependency tree shows:

1. **Direct dependencies**: Tasks listed in the root task's `dependencies` array
2. **Transitive dependencies**: Dependencies of dependencies (recursively)
3. **Blocking status**: Incomplete dependencies that are blocking the task

In the example above:
- W25 depends on W21 and W23
- W21 depends on W15
- W23 also depends on W21
- W15 has no dependencies (base task)

The complete dependency chain for W25 is: W15 → W21 → W23 → W25

## Use Cases

- **Planning**: Understand all work that must be completed before starting a task
- **Blocking analysis**: Identify which tasks are preventing work from starting
- **Impact assessment**: See the full scope of dependencies before making changes
- **Critical path analysis**: Identify the longest chain of dependencies
- **Dependency visualization**: Build dependency graphs or charts
- **Task prioritization**: Prioritize tasks based on their dependency chains

## Example Usage

### Get dependencies by identifier

```bash
curl -X GET \
  -H "Authorization: Bearer stride_dev_abc123..." \
  https://www.stridelikeaboss.com/api/tasks/W25/dependencies
```

### Get dependencies by numeric ID

```bash
curl -X GET \
  -H "Authorization: Bearer stride_dev_abc123..." \
  https://www.stridelikeaboss.com/api/tasks/125/dependencies
```

## Interpreting Results

### All dependencies completed

If all tasks in the dependency tree have `status: "completed"`, the root task is ready to start (status should be `open`).

### Blocked by dependencies

If any task in the dependency tree has a status other than `completed`, the root task is blocked (status will be `blocked`).

### Empty dependency tree

```json
{
  "task": {
    "id": 120,
    "identifier": "W20",
    "title": "Create database migration",
    "status": "open",
    "priority": "high",
    "complexity": "small",
    "dependencies": []
  },
  "dependencies": []
}
```

An empty `dependencies` array means the task has no prerequisites and can be started immediately.

## Workflow Integration

This endpoint is useful when:

1. **Claiming tasks**: Check if a task's dependencies are complete before claiming
2. **Planning sprints**: Understand the full scope of work needed
3. **Estimating timelines**: Calculate total time based on dependency chains
4. **Debugging blocked tasks**: Find out why a task is blocked
5. **Reordering work**: Identify which tasks must be completed first

## Notes

- The dependency tree is traversed recursively to show all levels
- Tasks may appear multiple times if they're dependencies of multiple tasks
- The `dependencies` field in each task shows the direct dependencies (task identifiers)
- Task must belong to the board associated with your API token
- Circular dependencies are not allowed (prevented by the system)
- Use numeric ID or identifier (W21, G10, etc.) in the URL

## See Also

- [GET /api/tasks/:id/dependents](get_tasks_id_dependents.md) - Get tasks that depend on this task
- [GET /api/tasks/:id](get_tasks_id.md) - Get task details
- [PATCH /api/tasks/:id](patch_tasks_id.md) - Update task dependencies
- [POST /api/tasks/claim](post_tasks_claim.md) - Claim a task (checks dependencies automatically)
