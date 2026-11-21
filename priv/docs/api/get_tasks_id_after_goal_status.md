# GET /api/tasks/:id/after_goal_status

Check whether completing a task armed its goal's `after_goal` hook, and get the
environment variables you need to run your local `## after_goal` section.

When the last child task of a goal is completed, the goal does not move to Done
straight away. Its `after_goal` hook is armed instead, and the goal waits for
your [PATCH /api/tasks/:id/after_goal](patch_tasks_id_after_goal.md) report.
The [PATCH /api/tasks/:id/complete](patch_tasks_id_complete.md) response says
so with an `after_goal` entry in its `hooks` list, but that response is large
and a client can lose it. This endpoint gives the same answer in a small,
separate response. The Stride plugin's hook calls it after a completion.

This endpoint is read-only. It never changes the task or the goal.

## Authentication

Requires a valid API token in the Authorization header:

```bash
Authorization: Bearer <your_api_token>
```

Any access to the board is enough, `read_only` included. No agent capability
is required. A workspace token names its board in the `X-Stride-Board` header
or the `board_id` parameter, as on every other task route (see
[GET /api/boards](get_boards.md)).

## Request

**Method:** GET
**Endpoint:** `/api/tasks/:id/after_goal_status`

### URL Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | string | Yes | Task ID (numeric) or task identifier (e.g., "W21"). A numeric ID outside the signed 64-bit range returns 404, the same as an ID that names no task. |

Pass the task you just completed. Passing the goal itself also works.

## Response

### Success (200 OK)

The hook is armed when either of these is true:

- the task is a goal whose `after_goal` hook is waiting for a report, or
- the task's parent is such a goal.

When it is armed:

```json
{
  "after_goal_armed": true,
  "goal_id": 4521,
  "goal_identifier": "G12",
  "env": {
    "GOAL_ID": "4521",
    "GOAL_IDENTIFIER": "G12",
    "GOAL_TITLE": "Add user notifications",
    "GOAL_DESCRIPTION": "Email and in-app notifications for task events",
    "BOARD_ID": "7",
    "BOARD_NAME": "Example Board",
    "HOOK_NAME": "after_goal"
  }
}
```

When it is not armed, the response always has these four keys and an empty
`env`:

```json
{
  "after_goal_armed": false,
  "goal_id": null,
  "goal_identifier": null,
  "env": {}
}
```

A task with no parent goal, a goal that never had an `after_goal` hook, and a
goal whose report already succeeded all return `false`.

### Response Fields

| Field | Type | Description |
|-------|------|-------------|
| `after_goal_armed` | boolean | `true` when the goal is waiting for an `after_goal` report |
| `goal_id` | integer or null | The goal's numeric ID. Use it in the `PATCH /api/tasks/:id/after_goal` URL. `null` when not armed |
| `goal_identifier` | string or null | The goal's identifier, such as `"G12"`. `null` when not armed |
| `env` | object | The environment to export before running `## after_goal`. Empty when not armed |

Every `env` value is a string. An empty goal title or description is `""`.

| `env` key | Value |
|-----------|-------|
| `GOAL_ID` | The goal's numeric ID |
| `GOAL_IDENTIFIER` | The goal's identifier |
| `GOAL_TITLE` | The goal's title |
| `GOAL_DESCRIPTION` | The goal's description |
| `BOARD_ID` | The board's numeric ID |
| `BOARD_NAME` | The board's name |
| `HOOK_NAME` | Always `"after_goal"` |

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
to the token's board. See [Token Scope](../AUTHENTICATION.md#token-scope).

```json
{
  "error": "Not authorized — board membership required",
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

### Other errors

This endpoint can also return the `400`, `406` and `429` responses that every
authenticated `/api` route shares. See [Errors](README.md#errors).

## Example Usage

```bash
curl -H "Authorization: Bearer <your_api_token>" \
  https://www.stridelikeaboss.com/api/tasks/W21/after_goal_status
```

## Notes

- When `after_goal_armed` is `true`, export every `env` key, run the
  `## after_goal` section of `.stride.md`, then report the result with
  [PATCH /api/tasks/:id/after_goal](patch_tasks_id_after_goal.md), using
  `goal_id` as the `:id`.
- The goal moves to Done only when a report with `exit_code: 0` arrives, or
  when the grace window described on that page runs out.

## See Also

- [PATCH /api/tasks/:id/after_goal](patch_tasks_id_after_goal.md) - Report the `after_goal` result
- [PATCH /api/tasks/:id/complete](patch_tasks_id_complete.md) - Complete a task
- [GET /api/tasks/:id/tree](get_tasks_id_tree.md) - Get a goal with its child tasks
