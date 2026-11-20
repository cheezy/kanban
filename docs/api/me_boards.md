# GET /api/me/boards, GET /api/me/boards/:id/columns/:name and POST /api/me/boards/:id/promote

The Stride mobile app's Boards tab
([design](../plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md), §6.9, §7.10): the
person's boards with their column counts, one column's cards, and promoting
several Backlog tasks to Ready in one step.

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

All three routes are plan-gated with the `mobile_app` feature. While paid
plans are enforced, a person whose plan does not include the Stride app gets
the [`plan_required` body](me_reviews.md#plans).

- `GET /api/me/boards` leaves out every board the plan does not unlock, as the
  app's other cross-board lists do. Its `idle_agents` count reads the agents'
  work on every board the person can access, as the Now screen's
  `ready_empty` item does; it names no board or task from one.
- The column read and the promote check the board's plan too, and only once
  the person is known to see the board, so a `403` never reveals a board.

## GET /api/me/boards

`200 OK` with every board the person can see, in the order `/boards` shows
them:

```json
{
  "data": [
    {
      "id": 55,
      "name": "Stride Development",
      "access": "owner",
      "group": "workspace",
      "workspace": {"id": 3, "name": "Engineering", "slug": "engineering"},
      "counts": {"backlog": 5, "ready": 0, "doing": 1, "review": 1, "done": 40},
      "idle_agents": 1
    }
  ]
}
```

- `access` is the person's access to the board: `owner`, `modify` or
  `read_only`.
- `group` sorts the board picker: `workspace` for a workspace of the person's
  Organization (one of the `workspaces` of [GET /api/me](get_me.md)),
  `personal` for their personal workspace, and `shared` for a board shared
  from anyone else's workspace. `workspace` is `null` for `shared`, so it
  never names a workspace the person does not belong to.
- `counts` are the live work and defect tasks in the board's Backlog, Ready,
  Doing, Review and Done columns: for each name, the `total` the
  [column read](#get-apimeboardsidcolumnsname) answers. Goals and archived
  tasks are left out, and a column the board does not have counts `0`.
- A name means one column, as everywhere else in Stride (a claim, a promote,
  the web's Backlog arrow): the board's leftmost column of that name, matched
  ignoring case and surrounding spaces. On a board with two columns of one
  name, only the leftmost is counted, so a count always equals the column
  read's `total`. The `/boards` card and the Now screen still add both
  columns up.
- `idle_agents` is the number of agents that worked on the board in the last
  24 hours and hold no task in Doing or Review on any board the person can
  see: the rule behind the Now screen's `ready_empty` item, so the header's
  "1 agent idle · Ready is empty" agrees with it.

## GET /api/me/boards/:id/columns/:name

One page of a column's cards, ordered by position, then id, 100 per page.
`name` is the column's name as it reads on the board, for example `Backlog`;
case and surrounding whitespace are ignored, and it is matched against the
board's own columns, never put into a query. `?page=` is 1-based and defaults
to `1`.

`200 OK`:

```json
{
  "data": {
    "board_id": 55,
    "column": {"id": 81, "name": "Backlog"},
    "tasks": [
      {
        "id": 8602,
        "identifier": "W2759",
        "title": "Add the Boards tab endpoints",
        "type": "work",
        "priority": "medium",
        "status": "open",
        "needs_review": false,
        "position": 0,
        "label": {"id": 7, "name": "mobile", "color": "blue"},
        "criteria_count": 6,
        "key_files_count": 5,
        "security_considerations_count": 2
      }
    ],
    "page": 1,
    "per_page": 100,
    "total": 1,
    "next_page": null
  }
}
```

- The cards are the column's live work and defect tasks; goals and archived
  tasks are left out, as the counts leave them out.
- `label` is the task's first label in the board card's order (by name,
  ignoring case, then id), or `null`.
- `criteria_count` is the number of non-blank lines of the task's acceptance
  criteria; `key_files_count` and `security_considerations_count` count its
  key files and security considerations. A captured task reads `0` for all
  three. The text of none of them is sent.
- `next_page` is the next page's number, or `null` on the last page.
- Pages are read by offset, so a task moved, added or archived in the column
  between two page reads can shift a card onto the page already read or past
  it. When `total` changes between pages, read the column again from page 1.
- The column is the board's leftmost column with that name (the lowest
  position), matched ignoring case and surrounding spaces. It is the column
  the board list counts, so `total` equals the list's count for that name,
  even on a board with two columns of one name.

The checks run in this order, and the first that fails answers:

1. the person's plan (`403 plan_required`);
2. `page`: an integer from 1 to 10000 (`400 Bad Request`);
3. the board: one the person holds access to, read-only included (`404`);
4. the board's plan (`403 plan_required`);
5. the column (`404`).

## POST /api/me/boards/:id/promote

Moves several tasks to the end of the board's Ready column in one
transaction.

```json
{"task_ids": [8602, 8603], "needs_review": true}
```

- `task_ids` is required: 1 to 100 task ids. A repeated id counts once.
- `needs_review: true` sets `needs_review` on every task it moves, so each is
  reviewed by a human before it reaches Done (the "Review them before Done"
  switch). `false` or absent leaves `needs_review` as it is.
- Any other key is ignored. Nothing about a task but its column, its position
  and `needs_review` is written: edits stay on the web.

`200 OK`, with the moved cards in their new order:

```json
{
  "data": {
    "promoted": [
      {
        "id": 8602,
        "identifier": "W2759",
        "title": "Add the Boards tab endpoints",
        "type": "work",
        "priority": "medium",
        "status": "open",
        "needs_review": true,
        "position": 3,
        "label": null,
        "criteria_count": 6,
        "key_files_count": 5,
        "security_considerations_count": 2
      }
    ],
    "already_ready": []
  }
}
```

### Promote rules

The promote follows the web's Backlog arrow, and every move goes through the
move path a drag on the web uses, so the positions, the status, the move
history and the parent goal's placement are written as the web writes them.

- Only a work or defect task in a column named Backlog moves. A goal, or a
  task in any other column, refuses the whole promote with `not_promotable`.
  A blocked task moves, as it does with the web's arrow, and stays blocked.
- A work or defect task already in Ready is left where it is and listed in
  `already_ready`; a goal in Ready refuses like any other goal.
  A retry, or two promotes of the same task at once, therefore never move a
  task twice: the second sees it in Ready.
- The tasks are appended to Ready in their Backlog order.
- Ready's WIP limit must hold all the moved tasks, or nothing moves.
- It runs with every column of the board locked and the tasks read
  `FOR UPDATE`, so a task archived, moved or deleted since the app read the
  column is seen as it is now. It succeeds or fails as a whole.

### Broadcasts

Once the promote commits, each moved task is broadcast to the board as a move
on the web is, and emits the same `[:kanban, :task, :moved]` event, so an open
board on the web updates card by card. Nothing is broadcast when a promote is
refused.

A promote that fills a `ready_empty` decision's empty Ready column is the
person's first action on it, and emits `[:kanban, :decision, :acted_on]`
with `action: :promote` and the device's platform as `via`
([telemetry guide](../telemetry.md#decision-events)).

### Check order

1. the person's plan (`403 plan_required`);
2. the board: one the person holds access to (`404`);
3. write access, `owner` or `modify` (`403 Forbidden`);
4. the board's plan (`403 plan_required`);
5. the body (`422` with `errors.task_ids` or `errors.needs_review`);
6. the board's Ready column (`422 no_ready_column`);
7. every id names a live task on this board (`404`);
8. every task is in Backlog or Ready (`422 not_promotable`);
9. Ready's WIP limit (`422 wip_limit_reached`).

## Errors

- `400 {"error": "Bad Request", "message": "page must be an integer from 1 to 10000."}`
  for a column read with a bad `page`.
- `401 {"error": "Missing or invalid Authorization header"}` when no
  `Authorization: Bearer` header is sent.
- `401 {"error": "Invalid access token"}` for an unknown, expired or revoked
  device token, for an agent API token, and for a device revoked while the
  request was in flight.
- `403` with the [`plan_required` body](me_reviews.md#plans).
- `403 {"error": "Forbidden", "message": "This needs write access to the board."}`
  for a promote by a person who can only read the board.
- `404 {"error": "Not Found"}` for a board the person holds no access to, an
  id that is not a positive integer, a column the board does not have, or a
  promote naming a task that is not a live task on this board. A promote
  that answers `404` moves nothing. A path that matches no route at all, such
  as an empty column name, gets the router's own `404 {"errors": {"detail":
  "Not Found"}}` instead.
- `409 {"error": "conflict", "message": "A task was moved by someone else at the same time. Try again."}`
  when a concurrent move kept changing a task in the middle of the promote.
- `422 {"errors": {"task_ids": ["can't be blank"]}}` for a missing or empty
  `task_ids`; `should have at most 100 item(s)` for more than 100 ids;
  `is invalid` for an id that is not a positive integer. `needs_review` that
  is not a boolean is `{"errors": {"needs_review": ["is invalid"]}}`.
- `422 {"error": "not_promotable", "message": "...", "task_ids": [...]}`
  with the tasks that are not work or defect tasks in Backlog or Ready;
  `422 {"error": "wip_limit_reached", "message": "..."}`;
  `422 {"error": "no_ready_column", "message": "..."}`.
