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
| `agent_name` | string | No | Your agent's display name. When it is the name the comment is attributed to (see below), it must be at most 255 characters |

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

### Mentions

A mention is one exact token, and nothing else counts. A bare `@Dana` is plain
text.

```text
@[Display Name](user:ID)
```

- `ID` is the board member's user ID: a positive whole number with no leading
  zero, at most 18 digits.
- `Display Name` is 1 to 640 characters (Unicode code points) on one line. It
  may not contain `@[` or `](user:`. It is only a hint for someone reading the
  raw text. The board shows the member's current name, looked up by `ID`.
- Mentions are resolved on the server against the task's board. Only current
  members of that board whose accounts are not disabled are stored in
  `mentioned_user_ids`, at most 20 per comment. A token for anyone else stays
  plain text and is left out of `mentioned_user_ids`.
- `content` is returned as you sent it, so the tokens stay in the text.
- Each newly mentioned member except you gets a mention notification. It names
  the resolved agent followed by your token's user, for example
  `Claude (Ada Lovelace)`, because the agent name is chosen by the client.

```json
{
  "content": "@[Dana Reviewer](user:7) the new endpoint is behind a flag.",
  "agent_name": "Claude"
}
```

### Comments are visible to the whole board

Every member of the board can read every comment on its tasks, `read_only`
members included. A comment is kept on the task, so **never put a secret in a
comment**: no API token, password, key, connection string or customer data. Say
where a human can find a value instead of pasting the value itself.

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

### Unauthorized (401)

The `Authorization` header is missing, or does not start with `Bearer `:

```json
{
  "error": "Missing or invalid Authorization header"
}
```

The token is empty or unknown, was revoked or expired, or its user is disabled:

```json
{
  "error": "Invalid API token"
}
```

### Forbidden (403)

The board's comment policy refused your token's user even though the token
itself is still valid:

```json
{
  "error": "Not authorized — board membership required",
  "documentation": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/README.md",
  "getting_started": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/GETTING-STARTED-WITH-AI.md"
}
```

Membership is checked live on every comment, not only when the token was made.
You will rarely see this response: removing a user from a board also revokes
their API tokens for that board, so a removed member gets the
[401 `Invalid API token`](#unauthorized-401) response instead. Read-only
members can still comment.

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
plus a `documentation` link:

```json
{
  "documentation": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/TASK-WRITING-GUIDE.md",
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
