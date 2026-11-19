# GET and PUT /api/me/notification_settings

The person's push notification settings, for the Stride mobile app's Settings
screen ([design](../plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md), §6.12, §7.9,
§8): the mode, the eight push switches, quiet hours and the one time zone
quiet hours follow. The switches are stored as the `push` column of the
person's notification preferences, beside in-app and email, so a web page
that reads those preferences sees the same values. The web preferences page
does not show them yet; its Push column and quiet-hours setting come with
W2768.

| Method | Path | What it does |
|---|---|---|
| GET | `/api/me/notification_settings` | Reads the person's push settings |
| PUT | `/api/me/notification_settings` | Changes any of them |

This is not an agent endpoint. Agents keep using the routes in the
[API reference](README.md) with their API token.

## Authentication

A device access token, sent as `Authorization: Bearer <token>`, exactly as for
[GET /api/me](get_me.md#authentication), with the same
[`X-Stride-App` header](get_me.md#the-version-header). An agent API token is
refused with `401`. A person reads and changes only their own settings; the
body never names a user.

## Plans

Both routes are plan-gated with the `mobile_app` feature. While paid plans
are enforced, a person whose plan does not include the Stride app gets the
[`plan_required` body](me_reviews.md#plans).

## GET /api/me/notification_settings

`200 OK`:

```json
{
  "data": {
    "mode": "decisions",
    "switches": {
      "review_requested": true,
      "task_unclaimed": true,
      "claim_expired": true,
      "after_goal_failed": true,
      "task_reviewed": false,
      "goal_completed": false,
      "target_status_changed": false,
      "mentioned": false
    },
    "quiet_hours_enabled": false,
    "quiet_start": "22:00",
    "quiet_end": "07:00",
    "time_zone": "Europe/London"
  }
}
```

- **The eight switches** are the event types that can push, decisions first
  (`review_requested`, `task_unclaimed`, `claim_expired`,
  `after_goal_failed`), then updates (`task_reviewed`, `goal_completed`,
  `target_status_changed`, `mentioned`). The other four event types,
  `task_assigned`, `board_access_changed`, `weekly_digest` and
  `comment_added`, never push and are not listed.
- **Defaults.** A person who has changed nothing has mode `decisions`, the
  four decision events on, the four updates off, and quiet hours off from
  22:00 to 07:00. Reading the settings writes nothing.
- **Times** are `HH:MM` in `time_zone`. `quiet_end` may be earlier than
  `quiet_start`, for quiet hours that span midnight.
- **`time_zone`** is the only zone quiet hours use. It is set from the first
  zone one of the person's devices reports, when it signs in or updates
  itself, and after that is changed only here; a later device, or a phone
  that changes zone, does not move it. It is `null` until a device or a
  change gives one. A device's own `time_zone`
  ([device routes](me_devices.md)) is a different setting.

## PUT /api/me/notification_settings

Send any of the keys above; a key that is not sent is left as it is, and
other keys are ignored:

```json
{"mode": "every", "switches": {"mentioned": false}, "quiet_hours_enabled": true}
```

`200 OK` with the settings after the change, in the `GET` shape.

- **Modes are presets.** Choosing a mode different from the stored one sets
  the eight switches to its defaults: `decisions` turns the four decision
  events on and the four updates off, `every` turns all eight on. Switches
  sent in the same request then win. Re-sending the stored mode changes no
  switch, so a switch the person changed is never reset by accident. Pushes
  follow only the switches, never the mode.
- **`switches` is partial.** Only the event types sent change. An unknown
  event type is ignored. A switch must be `true` or `false`; `null` and `""`
  are refused. `true` is refused for an event type that never pushes; `false`
  for one is accepted and changes nothing.
- **Times** are `HH:MM`, or `HH:MM:SS` with the seconds dropped, with two
  digits each. An offset such as `+05:00` or `Z`, a sign, one-digit hours or
  any other form is refused. Quiet hours that start when they end are
  refused.
- **Quiet hours need a time zone.** `quiet_hours_enabled: true` is refused
  while there is no `time_zone`, stored or sent in the same request.
- **`time_zone`** must be an IANA name spelled exactly as the tz database
  spells it, such as `Europe/London`. `null`, `""` and blanks are refused,
  whether or not a zone is stored, so a stored zone cannot be cleared.
- **The first change creates the row.** A person's settings row is created
  by their first device or their first change, whichever comes first.
- **Two changes at once** are applied one after the other, and neither loses
  a field. A switch change touches only the push switch, so it never undoes a
  change to the same event's in-app or email setting made at the same time on
  the web.

## Telemetry

A change that stores something emits `[:kanban, :push, :settings_changed]`
with the mode after the change, the names of the fields that changed and
`via`, the device's platform (`ios` or `android`); see the
[telemetry guide](../telemetry.md#push-events). A change to a switch is named
by its event type, and a mode change also names each switch its preset
changed. It never carries a value such as the time zone. A request that
changes nothing, or is refused, emits nothing.

## Errors

- `401 {"error": "Invalid access token"}` for a missing, expired or revoked
  device token, for an agent API token, and for a device revoked while the
  request was in flight.
- `403` with the [`plan_required` body](me_reviews.md#plans).
- `422 {"errors": {"<field>": ["<message>"]}}` for an unknown mode, a time
  that is not `HH:MM` or `HH:MM:SS`, quiet hours that start when they end,
  quiet hours turned on with no time zone (`needs a time zone`), an unknown
  or blank time zone, a switch that is not a boolean, or `true` for an event
  type that never pushes, keyed by that event type. It names the fields and their
  messages, never the values sent, and nothing is changed:

  ```json
  {"errors": {"time_zone": ["is not a known time zone"], "comment_added": ["never pushes"]}}
  ```
