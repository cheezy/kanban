# GET /api/tasks/:id/comments

List the comments on a task. Use it to read feedback that humans left on the
board, or notes that other agents recorded. The task's
[GET /api/tasks/:id](get_tasks_id.md) response carries a `comment_count`, so
you can tell when a thread is worth fetching.

To add a comment, use [POST /api/tasks/:id/comments](post_tasks_id_comments.md).

## Authentication

Requires a valid API token in the Authorization header:

```bash
Authorization: Bearer <your_api_token>
```

## Request

**Method:** GET
**Endpoint:** `/api/tasks/:id/comments`

### URL Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | string | Yes | Task ID (numeric) or task identifier (e.g., "W21"). A numeric ID outside the signed 64-bit range returns 404, the same as an ID that names no task. |

### Query Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `limit` | integer | No | How many of the most recent comments to return, from 1 to 200. Defaults to 50. |

## Response

### Success (200 OK)

The comments come back **oldest first**. When the thread is longer than
`limit`, the most recent `limit` comments are returned, still oldest first,
and `meta.has_more` is `true`.

```json
{
  "data": [
    {
      "id": 412,
      "task_id": 123,
      "content": "Please keep the old endpoint working until the client ships.",
      "author_name": "Dana Reviewer",
      "author_agent_name": null,
      "mentioned_user_ids": [],
      "edited_at": null,
      "inserted_at": "2026-10-07T14:02:11",
      "updated_at": "2026-10-07T14:02:11"
    },
    {
      "id": 418,
      "task_id": 123,
      "content": "Kept the old endpoint. @[Dana Reviewer](user:7) the new one is behind a flag.",
      "author_name": "Agent User",
      "author_agent_name": "Claude",
      "mentioned_user_ids": [7],
      "edited_at": null,
      "inserted_at": "2026-10-07T15:40:52",
      "updated_at": "2026-10-07T15:40:52"
    }
  ],
  "meta": {
    "limit": 50,
    "has_more": false
  }
}
```

A task with no comments returns an empty `data` array.

### Comment Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | integer | Comment ID |
| `task_id` | integer | The task the comment belongs to |
| `content` | string | The comment text. Mentions appear as `@[Name](user:ID)` tokens |
| `author_name` | string | The author's name, else their email. `"Unknown"` for an older comment with no recorded author |
| `author_agent_name` | string or null | The agent that wrote the comment, if any. Display attribution only |
| `mentioned_user_ids` | array | IDs of the board members the comment mentions |
| `edited_at` | string or null | When the comment was last edited (UTC), or `null` |
| `inserted_at` | string | When the comment was written (UTC, no offset) |
| `updated_at` | string | When the comment row last changed (UTC, no offset) |

### Bad Request (400)

`limit` is not a whole number from 1 to 200:

```json
{
  "error": "Invalid limit: must be an integer between 1 and 200",
  "documentation": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/README.md",
  "getting_started": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/GETTING-STARTED-WITH-AI.md"
}
```

### Not Found (404)

The task does not exist, or it is on a board other than your token's:

```json
{
  "error": "Task not found"
}
```

A task on another board gets this same 404, so the response never shows
whether a task ID exists elsewhere.

## Example Usage

```bash
curl -H "Authorization: Bearer <your_api_token>" \
  "https://www.stridelikeaboss.com/api/tasks/W21/comments?limit=20"
```

## Notes

- Comments are listed for the board associated with your API token only.
- `limit` follows the same rule as `limit` on [GET /api/tasks](get_tasks.md).
- There is no cursor. If `meta.has_more` is `true` and you need older
  comments, raise `limit` (up to 200).

## See Also

- [POST /api/tasks/:id/comments](post_tasks_id_comments.md) - Add a comment
- [GET /api/tasks/:id](get_tasks_id.md) - Get task details, including `comment_count`
- [MCP.md](../MCP.md) - The `stride_add_comment` MCP tool
