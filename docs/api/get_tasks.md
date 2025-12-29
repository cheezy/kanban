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
      "parent_goal_id": null,
      "parent_goal_identifier": null,
      "dependencies": [],
      "inserted_at": "2025-12-28T10:00:00Z",
      "updated_at": "2025-12-28T11:00:00Z"
    },
    {
      "id": 124,
      "identifier": "W22",
      "title": "Fix login bug",
      "description": "Users can't log in with special characters",
      "status": "open",
      "priority": "medium",
      "complexity": "low",
      "needs_review": true,
      "type": "task",
      "column_id": 5,
      "column_name": "Ready",
      "board_id": 1,
      "assigned_to_id": null,
      "assigned_to_name": null,
      "dependencies": [],
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

## Example Usage

### Get all tasks

```bash
curl -X GET \
  -H "Authorization: Bearer stride_dev_abc123..." \
  http://localhost:4000/api/tasks
```

### Get tasks in a specific column

```bash
curl -X GET \
  -H "Authorization: Bearer stride_dev_abc123..." \
  http://localhost:4000/api/tasks?column_id=5
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
