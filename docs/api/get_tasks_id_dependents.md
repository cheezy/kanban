# GET /api/tasks/:id/dependents

Get all tasks that depend on this task. This shows which tasks will be unblocked when this task is completed, helping you understand the downstream impact of completing the current task.

## Authentication

Requires a valid API token in the Authorization header:

```bash
Authorization: Bearer <your_api_token>
```

## Request

**Method:** GET
**Endpoint:** `/api/tasks/:id/dependents`

### URL Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | string | Yes | Task ID (numeric) or task identifier (e.g., "W21") |

## Response

### Success (200 OK)

Returns the task and a flat list of all tasks that depend on it:

```json
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
  "dependents": [
    {
      "id": 123,
      "identifier": "W23",
      "title": "Write authentication tests",
      "status": "in_progress",
      "priority": "medium",
      "complexity": "medium",
      "dependencies": ["W21"]
    },
    {
      "id": 125,
      "identifier": "W25",
      "title": "Deploy authentication to production",
      "status": "blocked",
      "priority": "high",
      "complexity": "small",
      "dependencies": ["W21", "W23"]
    }
  ]
}
```

### No Dependents

If no tasks depend on this task:

```json
{
  "task": {
    "id": 127,
    "identifier": "W27",
    "title": "Add authentication to mobile app",
    "status": "open",
    "priority": "medium",
    "complexity": "large",
    "dependencies": ["W25"]
  },
  "dependents": []
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

### Task Summary Fields

Each task object includes:

| Field          | Type    | Description                                                      |
|----------------|---------|------------------------------------------------------------------|
| `id`           | integer | Task ID                                                          |
| `identifier`   | string  | Human-readable identifier (W21, G10, etc.)                       |
| `title`        | string  | Task title                                                       |
| `status`       | string  | Current status: `open`, `in_progress`, `completed`, `blocked`    |
| `priority`     | string  | Priority: `low`, `medium`, `high`, `critical`                    |
| `complexity`   | string  | Complexity: `small`, `medium`, `large`                           |
| `dependencies` | array   | Array of task identifiers this task depends on                   |

### Dependents Array

- Returns a **flat list** of all tasks that have this task in their `dependencies` array
- Does **not** include transitive dependents (dependents of dependents)
- Only shows **direct dependents** - tasks that explicitly list this task as a dependency

## Understanding Dependents

In the example above:

- W21 (the queried task) is a **direct dependency** for W23 and W25
- Both W23 and W25 explicitly list "W21" in their `dependencies` array
- The `dependents` array shows the **immediate impact** of completing W21
- Only **direct dependents** are returned - tasks that explicitly depend on W21

To find **all** downstream tasks (including transitive dependents), you would need to recursively query the dependents of each dependent task. For example, if W27 depends on W25, you would need to call `/api/tasks/W25/dependents` to discover W27.

## Use Cases

- **Impact analysis**: Understand which tasks will be unblocked by completing this task
- **Prioritization**: Prioritize tasks that unblock the most other work
- **Planning**: See what work can proceed after this task is done
- **Deletion safety**: Check if a task can be safely deleted (no dependents)
- **Critical path**: Identify tasks on the critical path (tasks with many dependents)
- **Work visualization**: Build dependency graphs showing task relationships

## Example Usage

### Get dependents by identifier

```bash
curl -X GET \
  -H "Authorization: Bearer stride_dev_abc123..." \
  https://www.stridelikeaboss.com/api/tasks/W21/dependents
```

### Get dependents by numeric ID

```bash
curl -X GET \
  -H "Authorization: Bearer stride_dev_abc123..." \
  https://www.stridelikeaboss.com/api/tasks/121/dependents
```

## Interpreting Results

### Task has many dependents (high impact)

```json
{
  "task": {...},
  "dependents": [
    /* 10+ tasks */
  ]
}
```

This task is **critical** - completing it will unblock many other tasks. It should be prioritized.

### Task has no dependents (low impact)

```json
{
  "task": {...},
  "dependents": []
}
```

This task is a **leaf node** - no other tasks depend on it. It may be lower priority or can be safely deferred/deleted.

### Blocked dependents

If any dependent task has `status: "blocked"`, it means:

- The dependent is waiting for this task (and possibly others) to complete
- Completing this task may unblock it (if this is its last incomplete dependency)

## Workflow Integration

This endpoint is useful when:

1. **Completing tasks**: See what work you're unblocking
2. **Prioritizing work**: Focus on tasks that unblock the most other work
3. **Deleting tasks**: Verify no other tasks depend on this one
4. **Resource planning**: Understand which team members will be unblocked
5. **Sprint planning**: Identify high-impact tasks for the sprint
6. **Bottleneck analysis**: Find tasks that are blocking many others

## Practical Example

Before completing task W21 (Implement JWT authentication):

```bash
# Check what will be unblocked
curl -X GET \
  -H "Authorization: Bearer stride_dev_abc123..." \
  https://www.stridelikeaboss.com/api/tasks/W21/dependents
```

Response shows W23 and W25 are waiting. After completing W21:

- W23 can start immediately (all dependencies met)
- W25 must still wait for W23 to complete

## Deletion Safety Check

Before deleting a task, check for dependents:

```bash
curl -X GET \
  -H "Authorization: Bearer stride_dev_abc123..." \
  https://www.stridelikeaboss.com/api/tasks/W30/dependents
```

If `dependents` is empty, the task can be safely deleted without breaking dependency chains.

## Notes

- Returns only **direct dependents** (not transitive dependents)
- Dependents are returned as a flat array
- Task must belong to the board associated with your API token
- An empty array means no tasks depend on this one
- Use numeric ID or identifier (W21, G10, etc.) in the URL
- Tasks cannot be deleted if they have dependents (system prevents this)
- The response includes a count in the telemetry metadata

## See Also

- [GET /api/tasks/:id/dependencies](get_tasks_id_dependencies.md) - Get tasks that this task depends on
- [GET /api/tasks/:id](get_tasks_id.md) - Get task details
- [PATCH /api/tasks/:id](patch_tasks_id.md) - Update task dependencies
- [PATCH /api/tasks/:id/complete](patch_tasks_id_complete.md) - Complete task and unblock dependents
