# Stride MCP Server

Stride serves a [Model Context Protocol](https://modelcontextprotocol.io) (MCP)
server at `/api/mcp`. MCP clients such as Claude Code can use Stride through
typed, schema-validated tools instead of building `curl` commands by hand.

The tools wrap the task API. A claim or completion made through MCP goes through
the same code as the REST endpoint, so it is validated the same way and leaves
the task in the same state. Hook results, `explorer_result`, `reviewer_result`
and the completion gate all work exactly as described in the
[API documentation](api/README.md).

## Transport

- **Streamable HTTP, JSON only.** Every request is an HTTP `POST` to `/api/mcp`
  with a JSON-RPC 2.0 message, or a batch of messages, as the body. The answer
  is a single `application/json` body. The server never opens a server-sent
  events (SSE) stream.
- **Stateless.** The server issues no `Mcp-Session-Id` and keeps no session.
  `GET /api/mcp` and `DELETE /api/mcp` answer `405 Method Not Allowed` with
  `Allow: POST`. That includes a `GET` with `Accept: text/event-stream`, which
  is how a client checks for an SSE stream, so the client learns that there
  is none.
- **Protocol versions:** `2025-11-25`, `2025-06-18`, `2025-03-26` and
  `2024-11-05`. In `initialize` the server answers with the version the client
  asked for when it supports that version, and with `2025-11-25` otherwise. If a request sends an
  `MCP-Protocol-Version` header with any other value, the server answers `400`.
- **Notifications** such as `notifications/initialized` are accepted with
  `202 Accepted` and an empty body. So is a batch that holds only notifications.
  A batch may hold at most 50 messages.

## Authentication

The endpoint uses the API token you already use for the REST API, sent in an
`Authorization: Bearer` header. Every tool acts as the token's user, on the
token's board. A request with a missing, invalid or revoked token gets the
REST API's `401` before the server reads any JSON-RPC. Failed attempts count
toward the same failed-authentication rate limit as the REST API.

**Origin check.** If a request carries an `Origin` header, it must be Stride's
own origin. Any other origin, including `null`, gets `403`. This stops a web page
from driving the endpoint through the browser (DNS rebinding). MCP clients
outside a browser send no `Origin` header and are not affected.

## Setup in Claude Code

Keep the token in an environment variable. Never paste a token into a
configuration file that you commit.

```bash
export STRIDE_API_TOKEN="<your API token>"

claude mcp add --transport http stride https://www.stridelikeaboss.com/api/mcp \
  --header "Authorization: Bearer ${STRIDE_API_TOKEN}"
```

Or add the server to a project's `.mcp.json`. Claude Code expands
`${STRIDE_API_TOKEN}` from the environment, so the file itself holds no secret:

```json
{
  "mcpServers": {
    "stride": {
      "type": "http",
      "url": "https://www.stridelikeaboss.com/api/mcp",
      "headers": {
        "Authorization": "Bearer ${STRIDE_API_TOKEN}"
      }
    }
  }
}
```

To try a local development server, use `http://localhost:4000/api/mcp` and a
token created for a board on that server.

Run `/mcp` in Claude Code to check that the server is connected and lists six
tools. Then ask for the next Stride task: the client calls `stride_next_task`.

## Tools

`tools/list` returns every tool with a JSON Schema `inputSchema`. The argument
names and types are the same as in the REST API's
[OpenAPI specification](api/get_openapi_json.md).

| Tool | REST equivalent | Arguments |
|---|---|---|
| `stride_next_task` | [GET /api/tasks/next](api/get_tasks_next.md) | `skills_version`, `response_view` |
| `stride_claim_task` | [POST /api/tasks/claim](api/post_tasks_claim.md) | `before_doing_result` (required), `identifier`, `agent_name`, `skills_version` |
| `stride_complete_task` | [PATCH /api/tasks/:id/complete](api/patch_tasks_id_complete.md) | `id`, `after_doing_result`, `before_review_result`, `reviewer_result` (required), plus every other completion field |
| `stride_get_task` | [GET /api/tasks/:id](api/get_tasks_id.md) | `id` (required), `response_view` |
| `stride_list_tasks` | [GET /api/tasks](api/get_tasks.md) (paginated mode) | `limit`, `cursor`, `status`, `type`, `priority`, `assigned_to_id`, `parent`, `updated_since`, `column_id`, `label`, `response_view` |
| `stride_add_comment` | [POST /api/tasks/:id/comments](api/post_tasks_id_comments.md) | `id`, `content` (both required), `agent_name` |

Notes:

- **`id`** is a task identifier such as `W14`, or a numeric task id.
- **Integer arguments** also accept a number with a zero fractional part, such
  as `5.0`, as JSON Schema does.
- **Hooks still run on your machine.** `stride_claim_task` returns the
  `before_doing` hook, and `stride_complete_task` returns the `hooks` list. Run
  them exactly as you would after a REST call. The server never runs a hook.
- **`stride_complete_task`** returns the compact acknowledgement by default.
  The acknowledgement still carries `hooks`. Pass `"response_view": "full"` to
  get the whole task back.
- **`stride_list_tasks`** always returns one page, with slim summaries by
  default. This keeps large boards from filling the agent's context. Pass
  `meta.next_cursor` back as `cursor` to get the next page. On the last page
  `meta.next_cursor` is `null`. Pass `"response_view": "full"` to get whole
  tasks. A full-view page is capped by a byte budget, as described in
  [Full-view size limit](#full-view-size-limit). `label` takes a label name and
  filters exactly as `?label=` does on
  [GET /api/tasks](api/get_tasks.md#filtering-by-label).
- **`stride_add_comment`** is open to any member of the board, `read_only`
  included. The comment is stored with the token's
  user as its author. A token user with no membership on the board is refused
  with `error_code` `not_authorized` (HTTP status 403).
  The comment's `author_agent_name` is the token's agent model (as
  `ai_agent:<model>`), else `agent_name`, else the agent name the token last
  sent. This is the same order, and the same shared action, as
  [POST /api/tasks/:id/comments](api/post_tasks_id_comments.md), so a comment
  carries the same attribution over MCP and REST. `agent_name` is at most 255
  characters and is display attribution only. The tool returns the comment in
  the REST response shape.
  `stride_claim_task` and `stride_complete_task` still need `owner` or
  `modify` access, as they do over REST.

### Full-view size limit

Whole tasks are large, so `stride_list_tasks` caps a full-view page at
**100,000 bytes** of task JSON. The budget counts the UTF-8 bytes of the task
objects in `data`. The response envelope adds a little on top.

- Tasks are kept in id order until the next task would go over the budget. The
  rest of the page is left for the next call.
- A page with any tasks always returns at least one. A single task larger than
  the budget comes back alone, so paging always moves forward.
- In the full view, `meta` always carries `truncated`. It is `false` when the
  whole page fit, and `meta.next_cursor` is then the normal cursor.
- When `meta.truncated` is `true`, `meta.next_cursor` points after the last task
  returned. This holds even on what would have been the last page, so the cut
  tasks are never lost.
- Keep passing `meta.next_cursor` back as `cursor` until it is `null`. Together
  the pages hold every task exactly once.
- The cursor does not carry filters. Send the same `status`, `type`,
  `priority`, `assigned_to_id`, `parent`, `updated_since`, `column_id` and
  `label` with every page, as with [GET /api/tasks](api/get_tasks.md).
- The slim view is never cut and its `meta` has no `truncated` key. The REST
  endpoint `GET /api/tasks` is not affected either.

The `meta` of a cut page looks like this:

```json
{"next_cursor": "NzMwMg", "limit": 200, "truncated": true}
```

### Example: claim a task

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "stride_claim_task",
    "arguments": {
      "identifier": "W14",
      "agent_name": "Claude Opus 4.6",
      "before_doing_result": {"exit_code": 0, "output": "Already up to date.", "duration_ms": 850}
    }
  }
}
```

The response's `result` has `isError: false` and a `content` list with one text
item. That item's `text` is the JSON body `POST /api/tasks/claim` would have
returned: the claimed task under `data` and the `before_doing` hook under
`hook`.

## Errors

There are two kinds of failure.

**Protocol errors** are JSON-RPC errors:

| Code | Meaning | HTTP status |
|---|---|---|
| `-32700` | The body is not valid JSON | 400 |
| `-32600` | The body is not a valid JSON-RPC request, the batch is empty or holds more than 50 messages, or the `Content-Type` is not `application/json` (form and multipart bodies included) | 400 |
| `-32601` | Unknown method | 200 |
| `-32602` | Unknown tool, or arguments that do not match the tool's `inputSchema`. `error.data.errors` names each failing argument by path | 200 |

**Tool failures** come back as a successful JSON-RPC response whose result has
`isError: true`. This covers every refusal the REST API would give: task not
found, no write access, a failed hook result, or a completion rejected by the
completion gate. The text is the REST error body, plus two fields:

- `error_code`: the API error code, for example `task_not_claimable`,
  `not_authorized_to_complete`, `hook_validation_failed` or
  `completion_validation_failed`.
- `http_status`: the status the REST endpoint would have returned.

```json
{"error": "Task not found", "error_code": "not_found", "http_status": 404}
```

A task on another board is reported as not found, the same way the REST API
reports it.

## Related Documentation

- [API documentation](api/README.md)
- [OpenAPI specification](api/get_openapi_json.md)
- [Completion fields](api/patch_tasks_id_complete.md)
