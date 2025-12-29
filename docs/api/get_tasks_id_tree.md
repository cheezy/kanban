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

## Response

### Success (200 OK)

Returns the task with all its children in a nested tree structure:

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
        "task": {
          "id": 126,
          "identifier": "W23",
          "title": "Create database schema for users",
          "description": "Design and implement user table",
          "status": "completed",
          "priority": "critical",
          "complexity": "medium",
          "type": "task",
          "column_id": 8,
          "column_name": "Done",
          "parent_goal_id": 125,
          "parent_goal_identifier": "G10",
          "dependencies": [],
          "completed_at": "2025-12-28T13:30:00Z"
        },
        "children": []
      },
      {
        "task": {
          "id": 127,
          "identifier": "W24",
          "title": "Implement JWT token generation",
          "description": "Create functions to generate and validate JWT tokens",
          "status": "in_progress",
          "priority": "critical",
          "complexity": "medium",
          "type": "task",
          "column_id": 6,
          "column_name": "Doing",
          "parent_goal_id": 125,
          "parent_goal_identifier": "G10",
          "assigned_to_id": 5,
          "assigned_to_name": "Agent User",
          "dependencies": [126]
        },
        "children": []
      },
      {
        "task": {
          "id": 128,
          "identifier": "W25",
          "title": "Write authentication tests",
          "description": "Comprehensive test suite for auth system",
          "status": "blocked",
          "priority": "high",
          "complexity": "medium",
          "type": "task",
          "column_id": 5,
          "column_name": "Ready",
          "parent_goal_id": 125,
          "parent_goal_identifier": "G10",
          "dependencies": [127]
        },
        "children": []
      }
    ]
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

## Example Usage

### Get goal tree by ID

```bash
curl -X GET \
  -H "Authorization: Bearer stride_dev_abc123..." \
  http://localhost:4000/api/tasks/125/tree
```

### Get goal tree by identifier

```bash
curl -X GET \
  -H "Authorization: Bearer stride_dev_abc123..." \
  http://localhost:4000/api/tasks/G10/tree
```

## Use Cases

- View all child tasks of a goal
- Understand task dependencies within a goal
- Check progress on a multi-task goal
- Display hierarchical task structure
- Track which child tasks are completed/blocked/in-progress

## Response Structure

The response has a recursive structure:

```
{
  data: {
    task: {...},        // The parent task/goal
    children: [         // Array of child tasks
      {
        task: {...},    // Child task details
        children: []    // Child tasks can have their own children
      },
      ...
    ]
  }
}
```

Each level has:
- `task` - The task object with all its fields
- `children` - Array of child task objects (empty array if no children)

## Notes

- Works for both regular tasks and goals, but most useful for goals
- Regular tasks without children will have an empty `children` array
- The tree structure can be nested (children can have children)
- Shows the complete hierarchy of parent-child relationships
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
