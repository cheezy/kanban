# GET /api/me/targets and GET /api/me/targets/:id

The Stride mobile app's Targets list and Target screen
([design](../plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md), §6.16, §6.17,
§7.10): every delivery target the person can see with its status and task
counts, and one target the person owns with its goals and why it is at risk.

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

Goals on boards the plan does not unlock are left out, as the app's other
cross-board lists leave them out:

- a target's `goal_count` counts only its goals on unlocked boards, and a
  target with no goal on an unlocked board is not listed;
- the Target screen lists no goal row and no stalled goal from a locked
  board.

A target's `status`, estimate, `completed` and `total` stay the web's, whatever
the plan.

## The status is the web's

Both routes derive the status at read time, as the web does, in the device's
time zone (the `time_zone` sent with
[PUT /api/me/devices/current](me_devices.md)), else UTC. So a target whose date
is today in one zone and yesterday in another can be at risk on one phone and
missed on another, exactly as two browsers in those zones show it. The app
never computes a status.

`status` is one of `on_track`, `at_risk`, `missed` and `complete`, always as
that enum and never as translated text, so the app draws its own words in the
person's language.

## GET /api/me/targets

`200 OK` with the person's targets:

```json
{
  "data": {
    "targets": [
      {
        "id": 3,
        "name": "1.0 launch",
        "status": "at_risk",
        "target_date": "2026-12-15",
        "estimated_completion_date": "2026-12-19",
        "goal_count": 5,
        "completed": 6,
        "total": 20,
        "owner": true
      }
    ]
  }
}
```

### Which targets

The same targets as the web lists on `/agents` and the boards strip: every
active target with at least one member goal on a board the person can see,
soonest target date first. Ownership doesn't limit the list. Archived targets
are left out; they stay on the web.

### A target row

- `status`, `estimated_completion_date`, `completed` and `total` are the
  target's delivery rollup, the same read behind the delivery health band on
  `/agents`. `estimated_completion_date` is `null` when there is no estimate.
- `completed` and `total` count the member goals' child tasks, never the
  goals themselves, as the boards strip counts them.
- `goal_count` is the number of member goals (on boards the plan unlocks).
- `owner` is `true` when the person owns the target. Only the owner can open
  it with `GET /api/me/targets/:id`; everyone else reaches its goals through
  the [Goals list](me_goals.md).

### Check order

1. the person's plan (`403 plan_required`).

## GET /api/me/targets/:id

`200 OK` with the target, its goals and its risk:

```json
{
  "data": {
    "target": {
      "id": 3,
      "name": "1.0 launch",
      "status": "at_risk",
      "target_date": "2026-12-15",
      "estimated_completion_date": "2026-12-19",
      "goal_count": 1,
      "completed": 6,
      "total": 20,
      "owner": true
    },
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
    "risk": {
      "slipped": {"estimate": "2026-12-19", "target_date": "2026-12-15"},
      "stalled": [
        {
          "id": 4790,
          "identifier": "G88",
          "title": "Ship the Stride app",
          "agents": [{"name": "Claude", "reasons": ["stuck"]}]
        }
      ]
    }
  }
}
```

### Owner only

As on the web's `/targets/:id`, only the target's owner may read it. Anyone
else gets `404`, never `403`, so the answer never reveals that the target
exists. If ownership moves to someone else, the old owner's next read is a
`404`.

### The target and its goals

- `target` is the target's row, as on `GET /api/me/targets`, with `owner`
  always `true`. Its `completed` and `total` are the counts `/targets/:id`
  shows, and its `goal_count` is the number of goal rows.
- `goals` has one row per member goal, as on the
  [Goals list](me_goals.md#a-goal-row): its board, its task counts, its
  pending reviews and whether its `after_goal` hook failed.
- An owned target the web lists nowhere else (archived, or with no member
  goal the person can see) still answers `200`: its status and estimate come
  from its own progress, and it has no stalled goals.

### Risk

`risk` is present only when the target is `at_risk` and there is a reason to
give, as the risk explanation on `/agents` decides it:

- `slipped` is the estimate and the target date when the estimate is past the
  target date, else `null`;
- `stalled` lists each member goal a stalled agent is active on, by `id`,
  `identifier` and `title`, with its stalled agents by name and their
  `reasons`: `stuck` (holding an unarchived active task past the stuck
  threshold) and/or `dormant` (no activity past the dormancy threshold), in
  that order. An archived task left in Doing or Review never makes an agent
  `stuck`, as on [GET /api/me/agents](me_agents.md#agents).

Otherwise `risk` is `null`: a missed, on-track or complete target has none,
and neither has an at-risk target with no slipped estimate and no stalled
goal.

### Check order

1. the person's plan (`403 plan_required`);
2. the target: one the person owns (`404`).

## Telemetry

A read that answers `200` emits `[:kanban, :status, :viewed]` with `surface:
:targets` for the list and `surface: :target` for one target, and `via`, the
device's platform; see the [telemetry guide](../telemetry.md#status-events).
It never carries the target or its name. A refused read emits nothing.

## Errors

- `401 {"error": "Missing or invalid Authorization header"}` when no
  `Authorization: Bearer` header is sent.
- `401 {"error": "Invalid access token"}` for an unknown, expired or revoked
  device token, for an agent API token, and for a device revoked while the
  request was in flight.
- `403` with the [`plan_required` body](me_reviews.md#plans).
- `404 {"error": "Not Found"}` for a target the person does not own, an id
  that names no target, or an id that is not a positive integer.
- `426` for an app version below the platform's minimum and `429` after too
  many failed authentications from one address, as for
  [GET /api/me](get_me.md#errors).
