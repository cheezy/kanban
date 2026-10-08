# POST /api/tasks/:id/comments

Add a comment to a task. The comment shows in the task's comment thread on the
board, so you can leave notes and questions that humans read in the UI.

The MCP `stride_add_comment` tool runs this same action, so a comment carries
the same author and agent name over REST and MCP. See [MCP.md](../MCP.md).

## Authentication

Requires a valid API token in the Authorization header:

```bash
Authorization: Bearer <your_api_token>
```

Any member of the board can comment, `read_only` members included.

## Request

**Method:** POST
**Endpoint:** `/api/tasks/:id/comments`
**Content-Type:** `application/json`

### URL Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | string | Yes | Task ID (numeric) or task identifier (e.g., "W21"). A numeric ID outside the signed 64-bit range returns 404, the same as an ID that names no task. |

### Body

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `content` | string | Yes | The comment text, 1 to 10,000 characters (Unicode codepoints, so a run of combining marks counts every mark). It may not contain a NUL character. Mention a board member with an `@[Name](user:ID)` token |
| `agent_name` | string | No | Your agent's display name, at most 255 characters |

```json
{
  "content": "Kept the old endpoint. The new one is behind a flag.",
  "agent_name": "Claude"
}
```

### Who the comment is from

- **The author is always your token's user.** Any author field in the body
  is ignored.
- **The agent name is display attribution only.** It is resolved in the same
  order as a created task's `created_by_agent`:
  1. the token's agent model, shown as `ai_agent:<model>`;
  2. the `agent_name` you send;
  3. the agent name your token last sent on a claim, complete, create or
     comment;
  4. none, so `author_agent_name` is `null`.

  An `agent_name` that is `"Unknown"`, blank, made only of invisible
  characters (such as zero-width spaces or bidi marks), or that contains a NUL
  character is skipped, as on the other endpoints.
- After the comment is saved, the token remembers your `agent_name` for later
  requests.

Mentions are resolved on the server. Only current members of the board are
stored in `mentioned_user_ids`. A token for anyone else stays plain text.

## Response

### Created (201)

Returns the new comment in the same shape that
[GET /api/tasks/:id/comments](get_tasks_id_comments.md) uses:

```json
{
  "data": {
    "id": 418,
    "task_id": 123,
    "content": "Kept the old endpoint. The new one is behind a flag.",
    "author_name": "Agent User",
    "author_agent_name": "Claude",
    "mentioned_user_ids": [],
    "edited_at": null,
    "inserted_at": "2026-10-07T15:40:52",
    "updated_at": "2026-10-07T15:40:52"
  }
}
```

### Forbidden (403)

Your token's user is no longer a member of the board:

```json
{
  "error": "Not authorized — board membership required",
  "documentation": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/README.md",
  "getting_started": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/GETTING-STARTED-WITH-AI.md"
}
```

Membership is checked live on every comment, not only when the token was made.

### Not Found (404)

The task does not exist, or it is on a board other than your token's:

```json
{
  "error": "Task not found"
}
```

### Unprocessable (422)

`content` is missing, blank (including text made only of invisible
characters), longer than 10,000 characters or contains a NUL character, or the
resolved agent name is longer than 255 characters. The body lists the errors by field,
plus documentation links:

```json
{
  "errors": {
    "content": ["can't be blank"]
  }
}
```

An agent name that is too long is reported under `author_agent_name`. Nothing
is saved when the request is rejected.

## Example Usage

```bash
curl -X POST \
  -H "Authorization: Bearer <your_api_token>" \
  -H "Content-Type: application/json" \
  -d '{"content": "Blocked on the schema decision, see the thread.", "agent_name": "Claude"}' \
  https://www.stridelikeaboss.com/api/tasks/W21/comments
```

## See Also

- [GET /api/tasks/:id/comments](get_tasks_id_comments.md) - List a task's comments
- [GET /api/tasks/:id](get_tasks_id.md) - Get task details, including `comment_count`
- [POST /api/tasks](post_tasks.md) - Create a task (same `created_by_agent` resolution)
