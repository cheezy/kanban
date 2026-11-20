# GET /api/me/tasks/:id, POST /api/me/tasks/:id/comments, POST /api/me/tasks/:id/move_to_backlog and POST /api/me/tasks

The Stride mobile app's task actions
([design](../plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md), §6.1, §6.11, §7.10):
reading one task, replying on a released card, moving a released or expired
card back to Backlog, and capturing a new task into a board's Backlog.

This is not an agent endpoint. Agents keep using the routes in the
[API reference](README.md) with their API token.

## Authentication

A device access token, sent as `Authorization: Bearer <token>`, exactly as for
[GET /api/me](get_me.md#authentication), with the same
[`X-Stride-App` header](get_me.md#the-version-header). An agent API token is
refused with `401`.

Every response here, success or error, is `cache-control: private, no-store`
([caching](README.md#caching-of-the-person-api)).

## Plans

All four routes are plan-gated with the `mobile_app` feature. While paid
plans are enforced, a person whose plan does not include the Stride app gets
the [`plan_required` body](me_reviews.md#plans). The board's plan is checked
too, and only once the person is known to see the task or the board, so a
`403` never reveals either.

## Access

A task is found as the web finds its board: the person must hold access to
the task's board. A task on a board they hold no access to, or on a public
board they are not a member of, answers `404`, as an id that names no task
does. Both answers have the same body and run the same single lookup, scoped
to the person's boards, so neither the answer nor the time it takes tells
the two apart. This holds on every `/api/me/tasks/:id` route.

- Any member of the board, read-only included, may read a task and comment on
  it, as on the web.
- A move to Backlog and a capture need `owner` or `modify` access
  (`403 Forbidden` otherwise).

## Validation messages

A `422` with an `errors` object is answered in the device's language: its
`locale`, as registered with [the device](me_devices.md), resolved to one of
the locales Stride is translated into, else English. Match on the field and
on `error` codes, never on the message text.

## GET /api/me/tasks/:id

`200 OK` with the task, read-only, and its last 20 comments, oldest first:

```json
{
  "data": {
    "id": 4812,
    "identifier": "W2701",
    "title": "Add the member table",
    "type": "work",
    "priority": "high",
    "status": "open",
    "needs_review": false,
    "board_id": 55,
    "column": {"id": 127, "name": "Ready"},
    "description": "List the organization's members with their roles.",
    "acceptance_criteria": "The table lists every member\nEach row shows the role",
    "key_files": [
      {"file_path": "lib/kanban_web/live/org_live/members.ex", "note": "New table", "position": 0}
    ],
    "security_considerations": ["Only organization admins see email addresses"],
    "created_via": null,
    "archived_at": null,
    "comments": [
      {
        "id": 9120,
        "task_id": 4812,
        "content": "Released because the migration needs a decision: keep the old column?",
        "author_name": "Sam Rivera",
        "author_agent_name": null,
        "mentioned_user_ids": [],
        "edited_at": null,
        "inserted_at": "2026-11-20T09:14:02Z",
        "updated_at": "2026-11-20T09:14:02Z"
      }
    ],
    "has_more_comments": false
  }
}
```

- `acceptance_criteria` holds one criterion per line.
- A comment has the shape the agent API's
  [comments](get_tasks_id_comments.md) give it.
- `has_more_comments` is `true` when the task has comments older than the 20
  returned.
- `created_via` is `"mobile"` for a task captured in the app, else `null`.
- An archived task is returned with `archived_at` set.

## POST /api/me/tasks/:id/comments

Adds a comment through the web's comment path, so it is stored, mentioned and
notified exactly as a comment written on the web.

```json
{"content": "Keep the old column for now; drop it next release."}
```

- `content` is required: 1 to 10,000 characters. Any other key is ignored.
- The text is never put in a push notification: a mention's push names the
  task, not the comment.

`201 Created` with the comment, in the shape `GET /api/me/tasks/:id` gives
it, under `data`.

A reply on a released task or a failed goal is the person's first action on
that decision, unless someone already acted on it, and emits
`[:kanban, :decision, :acted_on]` with `action: :reply`, as does a move to
Backlog of a released task or an expired claim, with `action: :move`; `via`
is the device's platform
([telemetry guide](../telemetry.md#decision-events)).

### Check order

1. the person's plan (`403 plan_required`);
2. the task: one on a board the person holds access to (`404`, also for a
   task deleted in the meantime);
3. the board's plan (`403 plan_required`);
4. the content (`422` with `errors.content`).

## POST /api/me/tasks/:id/move_to_backlog

The **Move to Backlog** of a released or expired card. An agent's release
leaves the task open in Ready. Nothing releases an expired claim: the task
stays `in_progress` in Doing with its `claim_expires_at` in the past. This
moves either to the end of the board's Backlog. The body is not read.

`200 OK`, with the task's card as the [Boards tab](me_boards.md) shows it:

```json
{
  "data": {
    "moved": true,
    "task": {
      "id": 4812,
      "identifier": "W2701",
      "title": "Add the member table",
      "type": "work",
      "priority": "high",
      "status": "open",
      "needs_review": false,
      "position": 4,
      "label": null,
      "criteria_count": 2,
      "key_files_count": 1,
      "security_considerations_count": 1
    }
  }
}
```

### Move rules

The move goes through the move path a drag on the web uses, so the position,
the status, the move history and the parent goal's placement are written as
the web writes them.

- Only a work or defect task moves, from a column named Ready, or from a
  column named Doing when it is `in_progress` and its claim has expired. A
  goal, a task in any other column, or a task in Doing whose claim is still
  live is refused with `not_movable`, so a task an agent claimed, or renewed
  its claim on, in the meantime stays in Doing.
- Moving an expired claim also clears it, as a release does:
  `claimed_at`, `claim_expires_at` and `assigned_to_id` become `null`, so
  once the task is back in Ready any agent may claim it.
- A task already in Backlog is left where it is and answered with
  `moved: false`, so a retry never moves a task twice.
- Backlog's WIP limit must hold the task.
- It runs with every column of the board locked and the task read
  `FOR UPDATE`, so a task archived, moved or deleted since the app read it is
  seen as it is now.

Once the move commits, it is broadcast to the board as a move on the web is,
and emits the same `[:kanban, :task, :moved]` event. Nothing is broadcast for
a refusal or for a task already in Backlog.

### Check order

1. the person's plan (`403 plan_required`);
2. the task: one on a board the person holds access to (`404`);
3. write access, `owner` or `modify` (`403 Forbidden`);
4. the board's plan (`403 plan_required`);
5. the board's Backlog column (`422 no_backlog_column`);
6. the task is still live on this board (`404`, so an archived task is
   refused);
7. it is a work or defect task in Ready or Backlog, or one in Doing whose
   claim has expired (`422 not_movable`);
8. Backlog's WIP limit (`422 wip_limit_reached`).

## POST /api/me/tasks

Captures a task into a board's Backlog: the app's **New task** form.

```json
{
  "board_id": 55,
  "type": "defect",
  "title": "Sync button does nothing offline",
  "description": "Tapping Sync with no connection shows no message."
}
```

- `board_id`, `type` and `title` are required; `description` is optional.
- `type` is `work` or `defect`. A goal is refused with
  `{"errors": {"type": ["is invalid"]}}`.
- `title` is at most 255 characters.
- Any other key is ignored: a `parent_id`, `identifier`, `status`,
  `column_id`, `assigned_to_id` or `created_via` never reaches the task.

The task is created through the web's create path, at the end of Backlog,
with its own identifier, a history row and a board broadcast, and is stored
with `created_via: "mobile"` and the person as its creator. There is no draft
flag: it is an ordinary Backlog task, and whoever moves it to Ready decides
when it is ready.

`201 Created` with the task in the shape `GET /api/me/tasks/:id` gives it,
with no comments.

### Check order

1. the person's plan (`403 plan_required`);
2. the body (`422` with `errors.board_id`, `errors.type` or `errors.title`);
3. the board: one the person holds access to (`404`);
4. write access, `owner` or `modify` (`403 Forbidden`);
5. the board's plan (`403 plan_required`);
6. the board's Backlog column (`422 no_backlog_column`);
7. Backlog's WIP limit (`422 wip_limit_reached`);
8. the task's own fields (`422`, for example a title over 255 characters).

## Errors

- `401 {"error": "Missing or invalid Authorization header"}` when no
  `Authorization: Bearer` header is sent.
- `401 {"error": "Invalid access token"}` for an unknown, expired or revoked
  device token, for an agent API token, and for a device revoked while the
  request was in flight.
- `403` with the [`plan_required` body](me_reviews.md#plans).
- `403 {"error": "Forbidden", "message": "This needs write access to the board."}`
  for a move or a capture by a person who can only read the board.
- `404 {"error": "Not Found"}` for a task or board the person holds no access
  to, an id that is not a positive integer, or a task deleted, or for a move
  archived, in the meantime.
- `409 {"error": "conflict", "message": "A task was moved by someone else at the same time. Try again."}`
  when a concurrent move kept changing the task in the middle of a move.
- `422 {"errors": {field: [message]}}` for an invalid body, in the device's
  language: for example `{"errors": {"content": ["can't be blank"]}}`.
- `422 {"error": "not_movable", "message": "..."}`,
  `422 {"error": "no_backlog_column", "message": "..."}`,
  `422 {"error": "wip_limit_reached", "message": "..."}` and
  `422 {"error": "move_failed", "message": "..."}`.
