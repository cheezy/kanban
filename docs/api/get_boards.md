# GET /api/boards

List the boards your API token can be used on. Use it to find the board ids a
workspace token sends in the `X-Stride-Board` header or the `board_id`
parameter.

## Authentication

Requires a valid API token in the Authorization header:

```bash
Authorization: Bearer <your_api_token>
```

A token is one of two kinds:

- **Board token.** Scoped to one board. Every request acts on that board, and
  the board selectors below are ignored.
- **Workspace token.** Scoped to an Organization workspace. Only an org-admin
  of the workspace's Organization can create one, in the Tokens section of the
  workspace settings page, and the token acts as that org-admin. It reaches
  every board of the workspace that is AI Optimized and that its user can
  modify.

### Naming the board with a workspace token

With a workspace token, every request except `GET /api/boards` and the
[MCP endpoint's](../MCP.md#authentication) discovery calls must name the board
it acts on by id. Use either of these:

- the `X-Stride-Board` header, for example `X-Stride-Board: 42`
- the `board_id` parameter, in the query string or the JSON body

You can send more than one if they all name the same board. Send the header
and the query-string `board_id` at most once each: a repeat is refused even when
the values agree. The board is checked on every
request: it must be in the token's workspace, and the token's user must still
be able to modify it. A token whose user is no longer an org-admin keeps only
the board access that user was given directly.

| Situation | Status | Body |
|-----------|--------|------|
| No board named | `400` | `{"error": "Board selector required", "message": "..."}` |
| The header, the query-string `board_id` and the body `board_id` do not all name the same board, or the header or the query-string `board_id` is sent twice | `400` | `{"error": "Conflicting board selectors", "message": "..."}` |
| The board does not exist, is outside the token's workspace, or its user cannot modify it | `404` | `{"error": "Board not found"}` |

The `404` body is the same in every case, so a response never tells you
whether a board you cannot use exists.

A workspace token is revoked when its user stops being an org-admin of the
Organization, when they are removed from the workspace, or when the workspace
is archived. It expires after 90 days, like a board token.

## Request

**Method:** GET
**Endpoint:** `/api/boards`
**Parameters:** None. No board selector is needed.

## Response

### Success (200 OK)

Returns the boards the token can use, sorted by name. A board token sees its one
board. `meta.token_scope` is `"board"` or `"workspace"`.

```json
{
  "data": [
    {
      "id": 42,
      "name": "Payments",
      "description": "Payment service work",
      "workspace_id": 7
    },
    {
      "id": 43,
      "name": "Search",
      "description": null,
      "workspace_id": 7
    }
  ],
  "meta": {
    "token_scope": "workspace"
  }
}
```

A workspace token whose workspace has been archived lists no boards.

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

## Example Usage

```bash
curl -X GET \
  -H "Authorization: Bearer <your_api_token>" \
  https://www.stridelikeaboss.com/api/boards
```

Then work on one of the listed boards:

```bash
curl -X GET \
  -H "Authorization: Bearer <your_api_token>" \
  -H "X-Stride-Board: 42" \
  https://www.stridelikeaboss.com/api/tasks/next
```

## Notes

- MCP clients that use a workspace token send `X-Stride-Board` on every
  `POST /api/mcp` request. See [MCP.md](../MCP.md).
- Board tokens keep working exactly as before.

## See Also

- [GET /api/tasks/next](get_tasks_next.md) - Get the next task on the selected board
- [Authentication](../AUTHENTICATION.md) - How API tokens work
- [API reference](README.md) - Every endpoint
