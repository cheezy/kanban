# GET /api/me/agents and GET /api/me/goals/:id/after_goal

The Stride mobile app's Agents tab
([design](../plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md), §6.10, §7.10,
decision 9): the person's agents, the open goals they are working on, and a
goal's last `after_goal` attempt.

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

- `GET /api/me/agents` leaves out every board the plan does not unlock, as the
  app's other cross-board lists do: an agent's work on such a board counts
  toward nothing, and no goal on one is listed.
- `GET /api/me/goals/:id/after_goal` checks the goal's board's plan too, and
  only once the person is known to see the goal, so a `403` never reveals a
  goal.

## GET /api/me/agents

`200 OK` with the roster and the open goals its agents work on:

```json
{
  "data": {
    "agents": [
      {
        "name": "Claude Opus 4.6",
        "owner": {"id": 12, "name": "Sam Rivera"},
        "status": "working",
        "stuck": false,
        "dormant": false,
        "last_active_at": "2026-11-20T09:14:02Z",
        "current_task": {"identifier": "W2711", "title": "Add the member table"},
        "today": 3,
        "last_7d": 14
      }
    ],
    "goals": [
      {
        "id": 4790,
        "identifier": "G88",
        "title": "Organization members",
        "status": "in_progress",
        "board_id": 55,
        "counts": {"total": 9, "completed": 4, "doing": 1, "review": 1, "blocked": 0},
        "hook_failed": false
      }
    ]
  }
}
```

### agents

The roster `/agents` shows with its default time range, built the same way
(`Kanban.Agents.Roster`) from the same tasks: every work and defect task on a
board the person can see. An agent is every name that created or completed
one of those tasks, kept apart by the person who runs it, so an agent that
works on two boards is one agent. Agents are ordered by their latest
activity, newest first.

- `owner` is the person who runs the agent, by `id` and `name` only, or
  `null` when none is known. It never carries an email address.
- `status` is `working` when the agent has a task in Doing, `waiting` when it
  has one in Review and none in Doing, and `idle` otherwise.
- `stuck` is `true` when one of its Doing or Review tasks has had no activity
  for 60 minutes, and `dormant` when the agent has had none for 14 days.
  Dormant agents stay in the list, so the app can show them apart, as
  `/agents` does.
- `current_task` is its task in Doing, or `null`.
- `today` and `last_7d` count the tasks it completed today and in the last 7
  days, in the device's time zone (as registered with
  [the device](me_devices.md)), else UTC.

### goals

The open goals that have an agent on them now: the goal of each roster task
in Doing or Review that is not archived, when the goal is neither completed
nor archived. An archived task left in Doing or Review does not keep its
goal on the list. Newest first. The full list of goals is [GET /api/me/goals](me_goals.md).

`counts` are the goal's own tasks. The goal itself is never one of them: the
web's goal tree counts it as one of its own tasks (`total` is 1 plus its
tasks), and this route does not.

- `total` and `completed` count the goal's tasks as the `/agents` goal rows
  count them: a live task counts, an archived task that was completed counts
  as done work, and an archived task that was not completed counts in
  neither.
- `doing`, `review` and `blocked` count the goal's live tasks in the Doing and
  Review columns, and with the blocked status. `review` is what waits on the
  person, and `doing` what is in progress.
- `hook_failed` is `true` when the goal is waiting on `after_goal` and its
  last attempt's exit code is not `0`. The attempt itself is read with
  `GET /api/me/goals/:id/after_goal`.

### Check order

1. the person's plan (`403 plan_required`).

## GET /api/me/goals/:id/after_goal

`200 OK` with the goal's last `after_goal` attempt, the latest one an agent
reported:

```json
{
  "data": {
    "goal_id": 4790,
    "identifier": "G88",
    "status": "pending",
    "exit_code": 1,
    "duration_ms": 4000,
    "reported_at": "2026-11-20T09:14:02Z",
    "failed": true
  }
}
```

- `status` is `pending` while the goal waits on its `after_goal` hook,
  `succeeded` once the hook passed, and `null` before the goal's last task
  completed.
- `exit_code`, `duration_ms` and `reported_at` are the attempt's. All three
  are `null` for a goal no agent has reported an attempt for, and a value of
  the wrong type in a stored attempt is `null` rather than passed on.
- `failed` is `true` when `status` is `pending` and the exit code is not `0`,
  a missing one included, which is how Stride decides an attempt failed.

**The hook's output is never returned.** It can hold secrets or internal
paths, so the app shows it only where the web goal page shows it, with the
same redaction (decision 9). No web page shows it, so the response has no
`output` field.

Any member of the goal's board, read-only included, may read it, as on the
web.

### Check order

1. the person's plan (`403 plan_required`);
2. the goal: a goal on a board the person holds access to (`404`);
3. the board's plan (`403 plan_required`).

## Errors

- `401 {"error": "Missing or invalid Authorization header"}` when no
  `Authorization: Bearer` header is sent.
- `401 {"error": "Invalid access token"}` for an unknown, expired or revoked
  device token, for an agent API token, and for a device revoked while the
  request was in flight.
- `403` with the [`plan_required` body](me_reviews.md#plans).
- `404 {"error": "Not Found"}` for a goal on a board the person holds no
  access to, an id that names a work or defect task or no task at all, or an
  id that is not a positive integer.
