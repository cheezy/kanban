# GET /api/me/goals and GET /api/me/goals/:id

The Stride mobile app's Goals list and Goal screen
([design](../plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md), §6.18, §6.19,
§7.10): every goal on every board the person can see, and one goal's tasks
grouped by column.

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

Both routes are plan-gated with the `mobile_app` feature. While paid plans
are enforced, a person whose plan does not include the Stride app gets the
[`plan_required` body](me_reviews.md#plans).

- `GET /api/me/goals` leaves out every board the plan does not unlock, as the
  app's other cross-board lists do. Those goals are in no row and in no
  filter's count.
- `GET /api/me/goals/:id` checks the goal's board's plan too, and only once
  the person is known to see the goal, so a `403` never reveals a goal.

## GET /api/me/goals

`200 OK` with one page of the person's goals:

```json
{
  "data": {
    "goals": [
      {
        "id": 4790,
        "identifier": "G88",
        "title": "Ship the Stride app",
        "status": "in_progress",
        "board": {"id": 12, "name": "Mobile"},
        "target": {"id": 3, "name": "1.0 launch"},
        "counts": {"total": 9, "completed": 4, "doing": 2, "review": 1, "blocked": 0},
        "waiting_on_you": 1,
        "hook_failed": false
      }
    ],
    "filter": "open",
    "filters": {"open": 14, "done": 31, "no_target": 5},
    "page": 1,
    "per_page": 100,
    "total": 14,
    "next_page": null
  }
}
```

### Which goals

Every goal on every board the person can see, across all their workspaces:
a board they are a member of, or one their Organization admin role gives
them. The board list is worked out on the server and never taken from the
request. Archived goals are left out; they stay on the web, as archived
tasks do. Goals are newest first, 100 to a page.

### Parameters

- `filter` is `open` (the default), `done` or `no_target`:
  - `open`: goals that are not completed;
  - `done`: completed goals;
  - `no_target`: open goals with no target, or whose target is archived.

  Any other value is refused with `422 {"errors": {"filter": ["is invalid"]}}`.
- `page` is the 1-based page, from 1 to 10,000. Default 1. Any other value is
  refused with `400`.

`filters` carries every filter's count, whichever one was asked for, so each
filter can show its count. `total` is the asked-for filter's count, and
`next_page` is the next page, or `null` on the last one.

### A goal row

- `board` is the goal's board, by `id` and `name`.
- `target` is the goal's delivery target, by `id` and `name`, or `null` when
  it has none or its target is archived.
- `counts` are the goal's own tasks, as on the
  [Agents tab](me_agents.md#goals). The goal itself is never one of them.
  `total` and `completed` count the tasks as target progress counts them
  (D124): a live task counts, an archived task that was completed counts as
  done work, and an archived task that was not completed counts in neither.
  `doing`, `review` and `blocked` count live tasks only.
- `waiting_on_you` is the number of the goal's pending reviews: its live
  tasks in Review that need review and have no decision yet, the reviews the
  web's Review queue lists.
- `hook_failed` is `true` when the goal is waiting on `after_goal` and its
  last attempt's exit code is not `0`, as
  [GET /api/me/goals/:id/after_goal](me_agents.md#get-apimegoalsidafter_goal)
  reports it.

### Check order

1. the person's plan (`403 plan_required`);
2. `filter` (`422`);
3. `page` (`400`).

## GET /api/me/goals/:id

`200 OK` with the goal and its tasks:

```json
{
  "data": {
    "goal": {
      "id": 4790,
      "identifier": "G88",
      "title": "Ship the Stride app",
      "status": "in_progress",
      "board": {"id": 12, "name": "Mobile"},
      "target": {"id": 3, "name": "1.0 launch"},
      "counts": {"total": 9, "completed": 4, "doing": 2, "review": 1, "blocked": 0},
      "waiting_on_you": 1,
      "hook_failed": false
    },
    "agents": ["Claude"],
    "archived_done": 2,
    "groups": [
      {"status": "backlog", "tasks": []},
      {"status": "ready", "tasks": []},
      {
        "status": "doing",
        "tasks": [
          {
            "id": 4801,
            "identifier": "W2762",
            "title": "Add the goals routes",
            "type": "work",
            "status": "in_progress",
            "needs_review": false,
            "reviewable": false,
            "agent": "Claude",
            "in_column_since": "2026-11-20T08:02:11Z"
          }
        ]
      },
      {"status": "review", "tasks": []},
      {"status": "done", "tasks": []}
    ]
  }
}
```

- `goal` is the goal's row, as on `GET /api/me/goals`.
- `agents` are the agents who created or completed the goal or one of its
  tasks, the goal's first.
- `archived_done` is the number of the goal's archived tasks that were
  completed, for the "N archived" line under Done.
- `groups` is always five groups, in the web goal page's order: `backlog`,
  `ready`, `doing`, `review` and `done`. Each holds the goal's live tasks in
  that column, by position. A task in a column with any other name is in
  `backlog`, as on the web.

**The task list leaves archived tasks out; the counts don't.** The tasks are
the ones the web goal page lists. The header counts follow target progress
instead, so "4/9" on the Goal screen matches the same goal's row on its
target, even when some of its done work is archived. They can differ from the
web goal page's own counts, which leave archived tasks out.

### A task row

- `agent` is the agent on the task: the one that completed it, else the one
  that created it, or `null`.
- `reviewable` is `true` when the task is a pending review the person may
  decide, so the app opens the review rather than the task. A read-only
  member gets `false`.
- `in_column_since` is when the task entered its column. Every move is
  recorded in the task's history: a move on the web, a promote, a move to
  Backlog, and every move the agent workflow makes (a claim, an unclaim, a
  release of the claim when its holder loses access, a completion, the
  move to Done of a task that skips review, and a review that approves it,
  asks for changes or rejects it). So when the task's latest move took it
  into the column it is in now, that move's time is the answer. Otherwise,
  for a task an agent moved before its moves were recorded or a column
  renamed since, it is the later of that move and the time the agent
  workflow stamps for the column the task is in now: `claimed_at` in Doing,
  `review_requested_at` in Review and `completed_at` in Done. A task with
  neither uses the time it was created.

Any member of the goal's board, read-only included, may read it, as on the
web.

### Check order

1. the person's plan (`403 plan_required`);
2. the goal: a goal on a board the person holds access to (`404`);
3. the board's plan (`403 plan_required`).

## Telemetry

A read that answers `200` emits `[:kanban, :status, :viewed]` with `surface:
:goals` for the list and `surface: :goal` for one goal, and `via`, the
device's platform; see the [telemetry guide](../telemetry.md#status-events).
A refused read emits nothing.

## Errors

- `400 {"error": "Bad Request", "message": "page must be an integer from 1 to 10000."}`
  for a `page` that is not an integer from 1 to 10,000.
- `401 {"error": "Missing or invalid Authorization header"}` when no
  `Authorization: Bearer` header is sent.
- `401 {"error": "Invalid access token"}` for an unknown, expired or revoked
  device token, for an agent API token, and for a device revoked while the
  request was in flight.
- `403` with the [`plan_required` body](me_reviews.md#plans).
- `404 {"error": "Not Found"}` for a goal on a board the person holds no
  access to, an id that names a work or defect task or no task at all, or an
  id that is not a positive integer.
- `422 {"errors": {"filter": ["is invalid"]}}` for an unknown `filter`.
- `426` for an app version below the platform's minimum and `429` after too
  many failed authentications from one address, as for
  [GET /api/me](get_me.md#errors).
