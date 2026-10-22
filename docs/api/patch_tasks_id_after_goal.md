# PATCH /api/tasks/:id/after_goal

Report the result of a goal's `after_goal` hook. Call it after you run the
`## after_goal` section of `.stride.md`.

When the last child task of a goal is completed, the goal's `after_goal` hook is
armed and the goal waits in its column for this report. A report with
`exit_code: 0` moves the goal to Done. A report with any other exit code is
recorded, and the goal stays where it is so you can fix the problem and report
again.

To learn whether a completion armed the hook, and which goal to report against,
call [GET /api/tasks/:id/after_goal_status](get_tasks_id_after_goal_status.md).

## Authentication

Requires a valid API token in the Authorization header:

```bash
Authorization: Bearer <your_api_token>
```

The token's user needs owner or modify access to the board. No agent capability
is required. This is checked before the goal is looked up, so a refused caller
gets the same `403` whether the goal exists or what state it is in. A workspace
token names its board in the `X-Stride-Board` header or the `board_id`
parameter, as on every other task route (see [GET /api/boards](get_boards.md)).

## Request

**Method:** PATCH
**Endpoint:** `/api/tasks/:id/after_goal`
**Content-Type:** `application/json`

### URL Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | string | Yes | The goal's ID (numeric) or identifier (e.g., "G12"). A numeric ID outside the signed 64-bit range returns 404, the same as an ID that names no task. |

### Body

The three fields sit at the top level of the body. All three are required.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `exit_code` | integer | Yes | The section's exit code. `0` means it succeeded; any other integer means it failed |
| `output` | string | Yes | The section's output. May be `""`. It may not contain a NUL byte or invalid UTF-8 |
| `duration_ms` | integer | Yes | How long the section ran, in milliseconds. `0` or more |

```json
{
  "exit_code": 0,
  "output": "Pushed 4 commits to origin/main",
  "duration_ms": 2140
}
```

The types are checked strictly: a string such as `"0"` or a decimal such as
`1.5` is refused with a `422`. An empty `## after_goal` section did no work, so
report it as `{"exit_code": 0, "output": "", "duration_ms": 0}`.

The server adds a `reported_at` timestamp to the stored result. Do not send it.

## What happens

The goal keeps every report in its attempt history. The most recent report is
its current result.

- **`exit_code` is `0`.** The goal's `after_goal` hook is marked as succeeded
  and the goal moves to the Done column.
- **`exit_code` is anything else.** The report is recorded and the goal stays
  in its column, waiting. Fix the problem, run the section again and send a new
  report.
- **The hook already succeeded.** The report is recorded and nothing else
  changes. Sending the same report twice is safe.

### The grace window

Completing the goal's last child also starts a grace window of five minutes.
It exists for agents whose tooling predates this endpoint. If the goal is still
waiting when the window ends, the server marks the hook as succeeded and moves
the goal to Done itself.

That includes a goal whose latest report failed. A failed report does not stop
the window, so a goal can reach Done while its `after_goal` section has not
succeeded. If your section fails, fix it and report again within the window.

## Response

### Success (200 OK)

The body has two keys: `data`, the goal in the full task view (the same object
[GET /api/tasks/:id](get_tasks_id.md) returns under `data`), and
`current_skills_version`. Unlike GET /api/tasks/:id, it has no `comment_count`
key, and it has no `hooks` key.

```json
{
  "data": {
    "id": 4521,
    "identifier": "G12",
    "title": "Add user notifications",
    "type": "goal",
    "status": "open",
    "column_id": 41,
    "priority": "high",
    "complexity": "large",
    "parent_id": null,
    "needs_review": false
  },
  "current_skills_version": "1.0"
}
```

The example is shortened: the real `data` object carries every field of the
full task view.

The `data` object does not include the goal's `after_goal` status, result or
attempt history.

On the report that moves the goal to Done, `data` shows the goal as it was
**before** the move: the old `column_id`, and the `status` it had before. To see
where the goal is now, call [GET /api/tasks/:id](get_tasks_id.md) or
[GET /api/tasks/:id/after_goal_status](get_tasks_id_after_goal_status.md), which
answers `false` once the hook has succeeded.

`current_skills_version` is the newest Stride skills version. This endpoint
takes no `skills_version`, so it never adds a `skills_update_required` object.

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

The token's user does not have owner or modify access to the board. This
endpoint has its own `403` text, not the generic write-access text:

```json
{
  "error": "Not authorized to finalize this goal — board write access required",
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

### Unprocessable (422)

The checks run in this order, and the first one that fails answers. Each body
also carries the same `documentation` and `getting_started` URLs as the `403`
above.

The task is not a goal:

```json
{
  "error": "after_goal can only be reported against tasks of type goal"
}
```

The goal has no `after_goal` hook to report on, for example because its last
child task has not been completed yet:

```json
{
  "error": "Goal has no in-flight after_goal lifecycle (after_goal_status is nil)"
}
```

A body field is missing or has the wrong type:

```json
{
  "error": "after_goal payload requires {exit_code: integer, output: string, duration_ms: non-negative integer}"
}
```

`output` holds a NUL byte or invalid UTF-8. The output is refused, never
stripped, and the response never echoes it:

```json
{
  "error": "after_goal output contains characters that are not allowed (a NUL byte or invalid UTF-8)"
}
```

### Other errors

This endpoint can also return the `400`, `406` and `429` responses that every
authenticated `/api` route shares. See [Errors](README.md#errors).

## Example Usage

```bash
curl -X PATCH \
  -H "Authorization: Bearer <your_api_token>" \
  -H "Content-Type: application/json" \
  -d '{"exit_code": 0, "output": "Pushed 4 commits to origin/main", "duration_ms": 2140}' \
  https://www.stridelikeaboss.com/api/tasks/G12/after_goal
```

## Notes

- Report against the goal, not the child task you completed. `goal_id` from
  [GET /api/tasks/:id/after_goal_status](get_tasks_id_after_goal_status.md)
  names it.
- `output` is stored on the goal and kept in its attempt history, so keep
  secrets out of it.

## See Also

- [GET /api/tasks/:id/after_goal_status](get_tasks_id_after_goal_status.md) - Check whether `after_goal` is armed
- [PATCH /api/tasks/:id/complete](patch_tasks_id_complete.md) - Complete a task
- [AGENT-HOOK-EXECUTION-GUIDE.md](../AGENT-HOOK-EXECUTION-GUIDE.md) - How agents run hooks
