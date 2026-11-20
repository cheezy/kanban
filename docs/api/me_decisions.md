# GET /api/me/decisions and GET /api/me/reviews

The decisions waiting on the person, for the Stride mobile app's Now screen,
and the review queue, for its Review tab
([design](../plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md), §7.4, §7.5). Both
come from one builder, `Kanban.Decisions`, so the queue is always exactly the
review items of the Now screen, in the same order.

This is not an agent endpoint. Agents keep using the routes in the
[API reference](README.md) with their API token.

## Authentication

A device access token, sent as `Authorization: Bearer <token>`, exactly as for
[GET /api/me](get_me.md#authentication), with the same
[`X-Stride-App` header](get_me.md#the-version-header). An agent API token is
refused with `401`.

## Plans

Both routes are plan-gated with the `mobile_app` feature. While paid plans
are enforced, a person whose plan does not include the Stride app gets the
[`plan_required` body](me_reviews.md#plans). There is no board check on these
routes: only boards the person can access and that the plan unlocks contribute
items, so a board outside the plan never appears as an item. Two counts look
wider: `summary.agents_working`, and the idle-agent check behind a
`ready_empty` item, read every board the person can access, including boards
outside the plan; neither names a board or a task from one. A person removed
from a board stops seeing its items on the next request.

## GET /api/me/decisions

`200 OK`:

```json
{
  "data": {
    "items": [
      {
        "id": "review:task:8601",
        "kind": "review",
        "since": "2026-11-19T09:30:00Z",
        "task_id": 8601,
        "board_id": 55,
        "summary": {
          "identifier": "W2758",
          "title": "Add the decisions endpoints",
          "priority": "high",
          "agent": "Claude",
          "board": {"id": 55, "name": "Stride Development"}
        },
        "details": {
          "verdicts": [{"section": "acceptance_criteria", "status": "passed"}],
          "first_failed_note": null
        },
        "actions": ["open_review", "approve", "request_changes", "open_on_web"],
        "web_url": "https://www.stridelikeaboss.com/boards/55/tasks/8601/edit",
        "holds_up": 2,
        "held_identifiers": ["W2759", "W2760"]
      }
    ],
    "summary": {"waiting": 1, "held_up": 2, "agents_working": 1}
  }
}
```

Every key is always present; an unknown value is `null`. Fields are only ever
added, never removed or renamed, and an app ignores a `kind` or an action it
does not know.

### The items

- `id` is stable: `<kind>:task:<id>`, `hook_failed:goal:<id>` or
  `ready_empty:board:<id>`.
- `kind` is one of:

  | Kind | What waits | `details` |
  |---|---|---|
  | `review` | a task pending review | `verdicts` (the section pills, each `section` and `status`) and `first_failed_note` |
  | `released` | a task an agent released back to Ready that no one has claimed since; any later claim clears it for good, even one that expires or is released without a new notification | `reason` (the release notification's text) and `notification_id` |
  | `claim_expired` | a claim that expired while the task was in Doing | `claimed_at` and `expired_at` |
  | `hook_failed` | a goal whose `after_goal` hook failed | `exit_code` and `duration_ms`, never the hook's output |
  | `ready_empty` | a board with no Ready task, Backlog work and an idle agent | `idle_agents` and `backlog_count` |

- `since` is when the item started waiting.
- `ready_empty` reads the board's leftmost Ready column and its leftmost
  Backlog column (matched ignoring case and surrounding spaces), the
  columns [GET /api/me/boards](me_boards.md) counts and a promote fills,
  so `backlog_count` equals that list's Backlog count. A second column of
  the same name is not counted, and `move_to_backlog` is offered only while
  the leftmost Backlog is under its WIP limit.
- `task_id` is the task or goal, `null` for `ready_empty`.
- `summary` carries the task's `identifier`, `title`, `priority` and `agent`,
  all `null` for `ready_empty`, and its `board`.
- `actions` are the actions the server lets this person take on the item:
  `open_review`, `approve`, `request_changes`, `open_on_web`, `reply`,
  `move_to_backlog`, `view_attempt` and `open_backlog`. A read-only member is
  offered only `open_on_web` on a review. The actions are for the device
  asking: a phone is not offered `approve` on a review whose change is too
  large to approve on a phone (more than 10 files, more than 500 changed lines,
  or a diff cut at the stored cap), so a review item offers `approve` exactly
  when [GET /api/me/reviews/:task_id](me_reviews.md) answers
  `approvable_here: true` for the same device. A tablet keeps `approve` on
  any change. `request_changes` is never limited by size.
- `web_url` is where the item opens on the web. For a task it is the task's
  edit page when the person can write to the board, and the board itself for
  a read-only member, since the edit page refuses them.
- `holds_up` is how many unfinished tasks wait on the item, directly or
  through a chain, `null` for `ready_empty`, and `held_identifiers` names up
  to 5 of them, the nearest first.

### Order and cap

Items come back by `holds_up`, highest first, then by `since`, oldest first,
then by `id`, with every `ready_empty` item last. At most 100 items come back.

### The summary

- `waiting` counts every item waiting on the person, counted before the cap,
  so it is the Now badge.
- `held_up` counts the distinct tasks held up across every item.
- `agents_working` counts the agents holding a task in Doing on a board the
  person can access.

An empty inbox returns `{"data": {"items": [], "summary": {"waiting": 0,
"held_up": 0, "agents_working": 0}}}`, with `agents_working` still counting
any agent at work.

## GET /api/me/reviews

`200 OK` with the `review` items only, in the same order as
`GET /api/me/decisions` and with the same shape:

```json
{"data": [{"id": "review:task:8601", "kind": "review", "...": "..."}]}
```

The review items are taken before the decisions list's 100-item cap, so a
review never drops off the queue because other kinds filled the Now screen;
the queue itself is capped at 100. Open one with
[GET /api/me/reviews/:task_id](me_reviews.md).

## Telemetry

Each request that builds the decisions emits `[:kanban, :decisions, :built]`
with the number of items waiting, the build's duration and `source: :api`; see
the [telemetry guide](../telemetry.md#decisions-events). A refused request
(`401` or `403`) builds nothing and emits nothing.

The first time a person acts on a decision, from the app or the web, the
action emits `[:kanban, :decision, :acted_on]` with how long the decision
waited: an approval or request for changes on a review, a move to Backlog of
a released task or an expired claim, a promote that fills an empty Ready
column, or a reply on a released task or a failed goal. A later action on the
same decision emits nothing; see the
[telemetry guide](../telemetry.md#decision-events).

## Errors

- `401 {"error": "Invalid access token"}` for a missing, expired or revoked
  device token, for an agent API token, and for a device revoked while the
  request was in flight, which never receives the data.
- `403` with the [`plan_required` body](me_reviews.md#plans).
