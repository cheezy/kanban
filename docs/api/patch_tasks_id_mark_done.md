# PATCH /api/tasks/:id/mark_done

Mark a task in the Review column as done and move it directly to the Done column, bypassing the normal review process. This is typically used when a task needs to be completed without going through formal review.

## Authentication

Requires a valid API token in the Authorization header:

```bash
Authorization: Bearer <your_api_token>
```

## Request

**Method:** PATCH
**Endpoint:** `/api/tasks/:id/mark_done`
**Content-Type:** application/json

### URL Parameters

| Parameter | Type   | Required | Description                                          |
|-----------|--------|----------|------------------------------------------------------|
| `id`      | string | Yes      | Task ID (numeric) or task identifier (e.g., "W21")   |

### Request Body

This endpoint does not require a request body. The task will be moved to the Done column with status `completed`.

## Response

### Success (200 OK)

Returns the task that was marked as done:

```json
{
  "data": {
    "id": 123,
    "identifier": "W21",
    "title": "Implement authentication",
    "description": "Add JWT authentication to the API",
    "status": "completed",
    "priority": "high",
    "complexity": "medium",
    "needs_review": true,
    "type": "work",
    "column_id": 8,
    "column_name": "Done",
    "board_id": 1,
    "board_name": "Main Board",
    "assigned_to_id": null,
    "assigned_to_name": null,
    "completed_by_id": null,
    "completed_by_agent": null,
    "time_spent_minutes": null,
    "completion_summary": null,
    "review_status": null,
    "review_notes": null,
    "reviewed_at": null,
    "reviewed_by_id": null,
    "inserted_at": "2025-12-28T10:00:00Z",
    "updated_at": "2025-12-28T11:30:00Z",
    "completed_at": "2025-12-28T11:30:00Z"
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

Task is not in the Review column:

```json
{
  "error": "Task must be in Review column to mark as done"
}
```

### Not Found (404)

Task not found:

```json
{
  "error": "Task not found"
}
```

## Behavior

When marking a task as done:

1. **Validates task location**: Task must be in the Review column
2. **Moves to Done column**: Task is moved to the Done column
3. **Updates status**: Status is set to `completed`
4. **Sets completion timestamp**: `completed_at` is set to current time
5. **Broadcasts update**: Change is broadcast to all connected clients
6. **Does NOT set completion metadata**: Unlike the normal completion flow, this endpoint does NOT set:
   - `completed_by_id`
   - `completed_by_agent`
   - `completion_summary`
   - `time_spent_minutes`
   - `actual_complexity`
   - `actual_files_changed`
   - `review_status`
7. **Does NOT execute hooks**: This endpoint bypasses all workflow hooks (`after_review`, etc.)
8. **Does NOT unblock dependents**: This endpoint does NOT automatically check and unblock dependent tasks

## Use Cases

- **Emergency completion**: Complete a task that's stuck in review when the reviewer is unavailable
- **Self-review**: Mark your own work as done when formal review isn't required
- **Administrative override**: Manually complete a task as an administrator
- **Cleanup**: Mark old tasks as done when they're no longer relevant to review

## Workflow

This endpoint is typically used in these scenarios:

1. **Task completed and reviewed externally**: The review happened outside the system
2. **No review needed**: Task was incorrectly marked as needing review
3. **Administrative action**: Admin needs to manually complete a task
4. **Bypass stuck review**: Reviewer is unavailable and task needs to move forward

## Example Usage

### Mark task as done by identifier

```bash
curl -X PATCH \
  -H "Authorization: Bearer stride_dev_abc123..." \
  https://www.stridelikeaboss.com/api/tasks/W21/mark_done
```

### Mark task as done by numeric ID

```bash
curl -X PATCH \
  -H "Authorization: Bearer stride_dev_abc123..." \
  https://www.stridelikeaboss.com/api/tasks/123/mark_done
```

## Comparison with Other Completion Endpoints

| Endpoint                             | Purpose                          | Hooks Executed                       | Review Process                                                       |
|--------------------------------------|----------------------------------|--------------------------------------|----------------------------------------------------------------------|
| `PATCH /api/tasks/:id/complete`      | Complete task from Doing column  | Yes (`after_doing`, `before_review`) | Moves to Review or Done based on `needs_review`                      |
| `PATCH /api/tasks/:id/mark_reviewed` | Complete review and move to Done | Yes (`after_review`)                 | Requires review decision (`approved`/`changes_requested`/`rejected`) |
| `PATCH /api/tasks/:id/mark_done`     | Bypass review and mark as done   | No                                   | No review process, direct to Done                                    |

## Notes

- Task **must** be in the Review column to use this endpoint
- This endpoint **does not** execute any workflow hooks
- This endpoint **does not** set completion metadata (completed_by, completion_summary, etc.)
- This endpoint **does not** automatically unblock dependent tasks
- Use `PATCH /api/tasks/:id/mark_reviewed` instead if you want to go through the normal review process with:
  - Hook execution (`after_review`)
  - Completion metadata tracking
  - Automatic unblocking of dependent tasks
- The task's `status` will be set to `completed`
- The task's `completed_at` timestamp will be set
- This action is broadcast to all connected clients viewing the board
- This is a minimal bypass endpoint - it only updates status, completion time, and column

## See Also

- [PATCH /api/tasks/:id/complete](patch_tasks_id_complete.md) - Complete a task (triggers hooks)
- [PATCH /api/tasks/:id/mark_reviewed](patch_tasks_id_mark_reviewed.md) - Mark task as reviewed (normal review process)
- [GET /api/tasks/:id](get_tasks_id.md) - Get task details
- [GET /api/tasks/:id/dependents](get_tasks_id_dependents.md) - See which tasks will be unblocked
