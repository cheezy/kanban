# Dates and Times

This is the rule for showing an absolute date or time anywhere in
`lib/kanban_web`. It is written for contributors and agents adding a page, an
email or an export. The guard test
[`test/kanban_web/local_time_usage_test.exs`](../test/kanban_web/local_time_usage_test.exs)
enforces it as part of `mix test`. [Local Dates and Times](local-time.md) is
the full reference for the formatter.

## The rule

Format every date or time a person reads with `KanbanWeb.LocalTime` or the
`<.local_time>` component. Never format one yourself with
`Calendar.strftime/3`, `DateTime.to_string/1` or `NaiveDateTime.to_string/1`.
Those calls print the stored UTC value with an English pattern. A viewer in
Tokyo then sees a time nine hours off, with English month names. The W2727 to
W2734 sweeps converted the screens, emails and exports. The calls that remain
are in the files on [the allow-list](#the-allow-list).

Relative ages such as "5m ago" stay with `KanbanWeb.TimeAgo` and are outside
this rule.

## The formatter

- `KanbanWeb.LocalTime.format(value, style)` shifts a `DateTime` or
  `NaiveDateTime` to the viewer's zone. It renders the result with the current
  gettext locale's pattern.
- `KanbanWeb.LocalTime.format(value, style, zone)` takes an explicit zone. Use
  it where no viewer process exists, such as an export built for a known
  requester.
- `KanbanWeb.LocalTime.format_full/1` gives the tooltip text, which ends with
  the zone abbreviation.
- `KanbanWeb.LocalTime.utc_iso8601/1` gives the machine-readable UTC form.
- In a template, use the component. It renders a `<time>` element with the
  ISO 8601 UTC value in `datetime` and the full local time in `title`:

```heex
<.local_time value={@task.completed_at} style={:short_date} />
```

A `Date` is never shifted, a `NaiveDateTime` is read as UTC, and `nil`
renders an empty string. [Formatting a value](local-time.md#formatting-a-value)
lists every case.

## Styles

`KanbanWeb.LocalTime.styles/0` lists the styles:

- `:datetime`
- `:date`
- `:short_date`
- `:short_datetime`
- `:month_day`
- `:time`
- `:month_year`
- `:weekday_date`

Pick the style by what the reader needs, not by what fits. For example, use
`:time` only when the date is already on screen. The patterns are code
constants for each locale, never gettext msgids. Only month, weekday and AM/PM
names are translated. The table in
[Formatting a value](local-time.md#formatting-a-value) shows each style in
English, German and Japanese.

## How the zone is captured

1. `assets/js/app.js` reads the browser's IANA zone from
   `Intl.DateTimeFormat().resolvedOptions().timeZone`. It writes the zone to
   the `stride_tz` cookie and sends it as the `timezone` LiveSocket connect
   param.
2. `KanbanWeb.Plugs.Timezone` validates the cookie on every request. It stores
   the zone in the session and calls `KanbanWeb.LocalTime.put_timezone/1`, so
   a static render is already local.
3. `KanbanWeb.TimezoneOnMount` runs in every live_session. It prefers the
   connect param, then the session, then `"Etc/UTC"`. It assigns `@timezone`
   and calls `put_timezone/1` for the LiveView process.
4. The formatter reads the zone back with `KanbanWeb.LocalTime.timezone/0`,
   which returns `"Etc/UTC"` when nothing was put. It reads the language from
   the gettext locale.

The zone is display-only and is never an authorization input. A zone the tz
database rejects falls back to UTC.
[Where the zone comes from](local-time.md#where-the-zone-comes-from) has the
detail.

## What the guard test scans

The test reads every `.ex` and `.heex` file under `lib/kanban_web`. It fails
on any call or capture of these functions, outside the allow-listed files:

- `Calendar.strftime`
- `DateTime.to_string`
- `NaiveDateTime.to_string`

Each failure names the file and line. A call is caught wherever it sits, so
one at the end of a pipe split over several lines, or inside a string
interpolation, still fails the test.

The test does not match these:

- ISO 8601 serialisation, such as `DateTime.to_iso8601/1`. Examples are the
  JSON and SCIM responses, the API parameters, the metrics storage in
  `KanbanWeb.Telemetry.MetricsStorage`, and the `data-*` attributes on charts.
  Those values are machine formats, so they need no allow-list entry.
- `Date.to_string/1`, which the metrics exports use for file names.
- A function name mentioned in prose, such as `Calendar.strftime/3` in a
  moduledoc.
- A call after a `#` that starts a comment, whether the comment has its own
  line or ends a line of code. A `#` that opens an interpolation (`#{`) is not
  a comment.
- String interpolation of a timestamp, such as `"#{dt}"`, and
  `Kernel.to_string/1`. A source scan cannot see the argument's type, so
  review still has to catch these.

## The allow-list

The `@allowed` map in the test names each file that may format a timestamp
itself, and why:

| File                                          | Why                                                                             |
| --------------------------------------------- | ------------------------------------------------------------------------------- |
| `lib/kanban_web/local_time.ex`                | The formatter itself. Its private `strftime/2` is the one sanctioned call.      |
| `lib/kanban_web/emails/audit_stream_email.ex` | The audit-gap email has no viewer zone, so its sentence says the times are UTC. |

To add an entry, name one file and give a reason. Never list a directory. The
test also fails when an entry's file is missing or no longer makes a matching
call, so remove an entry when its call goes away. First, check whether
`KanbanWeb.LocalTime.format/3` with an explicit zone would do. An entry is
for output that cannot have a viewer zone, not for a screen that was not
converted yet.
