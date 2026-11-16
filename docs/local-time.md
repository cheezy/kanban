# Local Dates and Times

Every absolute date or time a page shows goes through one formatter,
`KanbanWeb.LocalTime`, so the timezone shift and the per-language patterns are
solved once rather than at each call site. Relative ages ("5m ago") stay in
`KanbanWeb.TimeAgo` and are not covered here.

## Where the zone comes from

The browser reports its IANA zone. `KanbanWeb.Plugs.Timezone` validates it for
every request and `KanbanWeb.TimezoneOnMount` for every LiveView process, and
both store it with `KanbanWeb.LocalTime.put_timezone/1`. Renderers read it back
with `KanbanWeb.LocalTime.timezone/0`, which returns `"Etc/UTC"` when nothing
was put. The zone is display-only and never an authorization input.

## Formatting a value

`KanbanWeb.LocalTime.format(value, style)` shifts the value to the process zone
and renders it with the current locale's pattern.
`KanbanWeb.LocalTime.format(value, style, zone)` takes an explicit zone and
ignores the process zone. Both functions follow these rules:

- A `DateTime` is shifted to the zone.
- A `NaiveDateTime` is treated as UTC and then shifted.
- A `Date` is formatted but never shifted. Asking for `:datetime` or `:time` on
  a `Date` renders its `:date` text, and `:short_datetime` its `:short_date`
  text, because a `Date` has no time.
- `nil` renders `""`.
- A zone the tz database does not accept falls back to `"Etc/UTC"`, using the
  same check as `KanbanWeb.Timezone.parse_timezone/1`.
- A locale without its own patterns uses the English ones.

| Style             | en                             | de                         | ja                   |
| ----------------- | ------------------------------ | -------------------------- | -------------------- |
| `:datetime`       | `November 10, 2026 at 6:56 PM` | `10. November 2026, 18:56` | `2026年11月10日 18:56` |
| `:date`           | `November 10, 2026`            | `10. November 2026`        | `2026年11月10日`       |
| `:short_date`     | `Nov 10, 2026`                 | `10. Nov. 2026`            | `2026/11/10`         |
| `:short_datetime` | `Nov 10, 6:56 PM`              | `10. Nov., 18:56`          | `11月10日 18:56`       |
| `:month_day`      | `Nov 10`                       | `10. Nov.`                 | `11月10日`             |
| `:time`           | `6:56 PM`                      | `18:56`                    | `18:56`              |
| `:month_year`     | `November 2026`                | `November 2026`            | `2026年11月`          |
| `:weekday_date`   | `Tue, Nov 10`                  | `Di., 10. Nov.`            | `11月10日 (火)`        |

`KanbanWeb.LocalTime.format_full/1` gives the tooltip form, which is the
`:datetime` text followed by the zone abbreviation, for example
`November 10, 2026 at 6:56 PM EST`. `KanbanWeb.LocalTime.utc_iso8601/1` gives
the machine-readable ISO 8601 UTC form.

## The component

Every HTML module imports `<.local_time>`. It renders a `<time>` element:

```heex
<.local_time value={@task.completed_at} style={:short_date} class="text-xs" />
```

- The `datetime` attribute is always ISO 8601 UTC, whatever the locale.
- The `title` attribute is the full local date and time with the zone
  abbreviation.
- The text is the requested style.
- A `nil` value renders nothing.

## Audit log rows and date filters

The organization and site-admin audit logs render each row's time with
`<.local_time>`. The text is the local `:datetime` style, which has no seconds.
The exact instant, to the microsecond, stays in the `datetime` attribute for
investigators.

The **From** and **To** date filters are not shifted. They still select whole
UTC days. The CSV, JSON and signed exports read the same filters, and the
signed manifest records them, so one URL returns the same events for every
viewer. A note under the filter form says this. A notification's relative age,
such as "5m ago", keeps its `KanbanWeb.TimeAgo` text and gets the UTC instant
as its `datetime` attribute and the full local time as its `title`. Other
relative ages, such as the audit-streaming backlog's "oldest from" age, are
still bare `KanbanWeb.TimeAgo` text.

Inside a gettext string, use `KanbanWeb.LocalTime.format/2`, not
`format_full/1`. For a viewer in UTC, `format_full/1` adds the abbreviation
"UTC", which would put the literal back into the sentence.

## Translations

The strftime patterns are code constants in `KanbanWeb.LocalTime`. They are
never gettext msgids, so editing a `.po` file cannot inject a format directive.
Only the month, weekday and AM/PM names are translated. They live in
`KanbanWeb.LocalTime.Names` as `pgettext` calls with the contexts
`month name`, `month abbreviation`, `weekday name`, `weekday abbreviation` and
`time of day`. The context lets the full and the abbreviated "May" be
translated separately.

Spanish, French and Portuguese month and weekday names are lower case.
Japanese and Chinese patterns use numeric months. `%p` upper-cases the AM/PM
marker, so only a locale whose marker reads correctly in upper case should use
a 12-hour pattern.

To add a locale, add its patterns to `@patterns` and translate the 40 name
entries in its `default.po`. To add a style, add it to `@styles`, give every
locale a pattern for it, and extend the component's `values:` list.
