# GET /api/tasks/next

Get the next available task from the Ready column that matches your agent's capabilities.

## Authentication

Requires a valid API token in the Authorization header:

```bash
Authorization: Bearer <your_api_token>
```

## Request

**Method:** GET
**Endpoint:** `/api/tasks/next`

### Query Parameters

Both parameters are optional, and neither changes which task is returned.

| Parameter | Values | Default | Effect |
|---|---|---|---|
| `skills_version` | Your installed Stride skills version, e.g. `1.0` | absent | Every 200 response that returns a task carries `current_skills_version`; the 403 and 404 bodies do not. When the version you send is strictly older than it, the response also carries a `skills_update_required` object. An equal, newer or unreadable version adds nothing |
| `response_view` | `slim` | absent (full) | `slim` returns an eleven-key summary of the task instead of the full object, the same summary [GET /api/tasks](get_tasks.md#selecting-the-response-view) uses. Any other value returns the full task. The skills-version keys are present under both views |

## Response

### Success (200 OK)

Returns the first task that meets every condition in
[Task Selection Logic](#task-selection-logic) below.

```json
{
  "data": {
    "id": 123,
    "identifier": "W21",
    "title": "Implement authentication",
    "description": "Add JWT authentication to the API",
    "status": "open",
    "priority": "high",
    "complexity": "medium",
    "needs_review": true,
    "type": "work",
    "column_id": 5,
    "created_by_id": 1,
    "created_by_agent": null,
    "assigned_to_id": null,
    "completed_by_agent": null,
    "time_spent_minutes": null,
    "review_status": null,
    "review_report": null,
    "parent_id": null,
    "dependencies": [],
    "inserted_at": "2025-12-28T10:00:00Z",
    "updated_at": "2025-12-28T10:00:00Z",
    "completed_at": null
  },
  "current_skills_version": "1.0"
}
```

### Forbidden (403)

Your token is a board token, and the user who created it no longer has access
to the token's board. Every read checks this again on every request, so a board
token stops reading once its user is removed from the board, or stops being an
org-admin of (or leaves) the Organization their access came from. Any access is
enough to read, read-only included. See [Token Scope](../AUTHENTICATION.md#token-scope).

```json
{
  "error": "Not authorized — board membership required",
  "documentation": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/README.md",
  "getting_started": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/GETTING-STARTED-WITH-AI.md"
}
```

### Not Found (404)

No tasks available that match your capabilities:

```json
{
  "error": "No tasks available in Ready column matching your capabilities"
}
```

## Example Usage

```bash
curl -X GET \
  -H "Authorization: Bearer stride_dev_abc123..." \
  https://www.stridelikeaboss.com/api/tasks/next
```

## Task Selection Logic

A task is a candidate only when **all** of these hold:

1. **Column**: It is in the column named Ready on your token's board
2. **Type**: It is a `work` or `defect` task. Goals are never offered
3. **Human Task**: Its `human_task` flag is `false`
4. **Status**: It is `open`, or it is `in_progress` and its claim has expired
5. **Archived**: It is not archived
6. **Capabilities**: Your token holds every entry in its `required_capabilities`. A task with no required capabilities matches every token, and a token with no capabilities is not filtered at all
7. **Dependencies**: Every task in its `dependencies` array is completed
8. **Assignment**: It is unassigned, or assigned to the user who owns your token

Candidates are then ordered:

1. **Priority**, highest first: `critical`, `high`, `medium`, `low`
2. **Position in the Ready column**, top first, for tasks of equal priority

The first candidate in that order whose `key_files` do not overlap a task in
progress in Doing or Review is returned. The same rules, with examples, are in
[How the next task is chosen](../AGENT-CAPABILITIES.md#how-the-next-task-is-chosen).

## Available Capabilities

Agent capabilities are configured in your API token. Common capabilities include:

- `code_generation` - Writing new code, implementing features
- `testing` - Writing and running tests
- `documentation` - Writing documentation
- `code_review` - Reviewing code and changes
- `devops` - CI/CD, Docker and deployment pipelines

A task's `required_capabilities` accepts only the 16 values listed in
[Standard Capabilities](../AGENT-CAPABILITIES.md#standard-capabilities).

## Notes

- This endpoint does NOT claim the task - it only shows what's available
- Use `POST /api/tasks/claim` to actually claim a task
- Without `response_view=slim`, the response includes ALL task fields (same as GET /api/tasks/:id)
- A Ready task whose `key_files` (files being modified) overlap a task in progress in Doing or Review is skipped. A claim that names a task with `identifier` does not run this check
- Claims expire after 60 minutes if the task is not completed. An expired claim stays in Doing until it is unclaimed or moved back to Ready

## See Also

- [POST /api/tasks/claim](post_tasks_claim.md) - Claim a task to start working on it
