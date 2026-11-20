# The me:inbox and me:agents channels

The Stride mobile app's two live channels
([design](../plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md), §7.7), joined on
the socket at `/api/socket`. `me:inbox` keeps the Now screen's decisions up
to date and `me:agents` keeps the Agents tab's roster and goal progress up to
date, so the app does not poll.

This is not an agent surface. Agents keep using the routes in the
[API reference](README.md) with their API token.

## Joining

First connect the socket with a single-use socket token, as
[POST /api/me/socket_token](me_socket_token.md#connecting) describes. Then
join `me:inbox`, `me:agents` or both. Join parameters are ignored: each
channel is always the connected person's own.

A join is checked again, even though the connect was accepted:

- the device must still be signed in and its user still enabled. A device
  revoked after the connect cannot join, and revoking it later closes the
  socket and every channel on it
  ([revoking](me_socket_token.md#revoking-the-device-closes-the-socket));
- while paid plans are enforced, the person's plan must include the Stride
  app (the `mobile_app` feature).

A refused join gets an error reply with one `reason`:

| `reason` | Why |
|---|---|
| `"unauthorized"` | The device was revoked, or its user disabled, after the connect. |
| `"plan_required"` | Paid plans are enforced and the person's plan does not include the Stride app. |

A plan refusal emits `[:kanban, :plan, :feature_refused]` with
`feature: :mobile_app` and `surface: :channel`
([telemetry](../telemetry.md)).

Every rebuild repeats these checks on a freshly read device, user and
Organization membership. When one fails — the device was revoked, the user
disabled, or the plan no longer includes the app — the channel closes with no
reason and pushes nothing more. Rejoining then gets the `unauthorized` or
`plan_required` reply that says why.

## Events

Each channel pushes one event, always with the full state:

| Channel | Event | Payload |
|---|---|---|
| `me:inbox` | `decisions` | The same body as [GET /api/me/decisions](me_decisions.md#get-apimedecisions) for this device: `{"data": {"items": [...], "summary": {...}}}` |
| `me:agents` | `agents` | The same body as [GET /api/me/agents](me_agents.md#get-apimeagents), taken in the device's time zone: `{"data": {"agents": [...], "goals": [...]}}` |

The keys are the REST keys, with the same contract: fields are added, never
removed or renamed.

- **On join** the channel pushes its event straight away, so an app that
  reconnects gets the full state and never merges events it missed.
- **After a change** the channel rebuilds the whole state and pushes it only
  when it differs from the last one it pushed. It never pushes a partial
  diff, and an unchanged rebuild pushes nothing.
- **At most once a second.** The first change schedules a rebuild one
  second later; every change until then is covered by that one rebuild. A
  burst of a hundred task changes costs one rebuild and at most one push.

## What triggers a rebuild

`me:inbox` listens to the person's notification topic and to the task topic
of every board it covers. Any message on them asks for a rebuild: a task
created, moved, claimed, completed or reviewed, a membership change, a new
notification or a notification marked read.

`me:agents` listens to the agents feed of every board it covers (a task
created, claimed, completed or reviewed) and to `board_access_changed`
notifications. Other notifications are ignored. A goal's counts can move
without an agent event, for example when a person drags a task to Done;
`me:agents` picks that up on its next rebuild, not at once.

## Which boards are covered

Both channels cover every board the person can access, in every workspace,
including the boards an Organization admin reaches without a membership,
and only the boards the plan unlocks: the boards the REST bodies read. A
board the person cannot see is never subscribed to.

Every rebuild re-reads those boards first, then subscribes to the boards the
person gained and drops the boards they lost. So being added to a board, or
removed from one, is picked up by the rebuild the change itself triggers (a
`board_access_changed` notification, or the board's membership change), and
the removed board's changes stop reaching the channel. Every push is built
for the person from their current access, never forwarded from a broadcast,
so a subscription that is briefly stale can cause an extra rebuild but never
shows a board the person lost.

## Telemetry

Every `me:inbox` rebuild builds the decisions with source `channel`, so it
emits `[:kanban, :decisions, :built]` with `source: :channel`, as the REST
route emits it with `source: :api` ([decisions telemetry](me_decisions.md#telemetry)).
