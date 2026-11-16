defmodule KanbanWeb.LocalTime do
  @moduledoc """
  The viewer's current timezone for the running process, and the one place
  every page formats an absolute date or time in it.

  `KanbanWeb.Plugs.Timezone` sets the zone for every browser request and
  `KanbanWeb.TimezoneOnMount` for every LiveView process, the same way
  `Gettext.put_locale/2` holds the current locale. Renderers read it with
  `timezone/0` instead of having the zone threaded through as an attr.

  The value put here has already been validated against the tz database. It is
  only for display and day bucketing, and is never an authorization input.

  ## Formatting

  `format/2` shifts a `DateTime` (or a `NaiveDateTime`, treated as UTC) to the
  process zone and renders it with the current locale's pattern for one of the
  styles below. A `Date` is formatted but never shifted. Month, weekday and
  AM/PM names come translated from `KanbanWeb.LocalTime.Names`; the patterns
  themselves are code constants, never gettext msgids, so a translation cannot
  change a format directive. A locale without its own patterns uses `"en"`.

  | Style             | en example                       |
  | ----------------- | -------------------------------- |
  | `:datetime`       | `November 10, 2026 at 6:56 PM`   |
  | `:date`           | `November 10, 2026`              |
  | `:short_date`     | `Nov 10, 2026`                   |
  | `:short_datetime` | `Nov 10, 6:56 PM`                |
  | `:time`           | `6:56 PM`                        |
  | `:month_year`     | `November 2026`                  |
  | `:weekday_date`   | `Tue, Nov 10`                    |

  Relative ages ("5m ago") stay in `KanbanWeb.TimeAgo`.
  """

  alias KanbanWeb.LocalTime.Names
  alias KanbanWeb.Timezone

  @default "Etc/UTC"
  @key {__MODULE__, :timezone}

  @styles [:datetime, :date, :short_date, :short_datetime, :time, :month_year, :weekday_date]

  @ja_zh %{
    datetime: "%Y年%-m月%-d日 %H:%M",
    date: "%Y年%-m月%-d日",
    short_datetime: "%-m月%-d日 %H:%M",
    month_year: "%Y年%-m月",
    time: "%H:%M",
    weekday_date: "%-m月%-d日 (%a)"
  }

  # `%p` upcases the translated AM/PM marker (and `%P` downcases it), so only a
  # locale whose marker reads correctly in upper case uses a 12-hour pattern.
  @patterns %{
    "en" => %{
      datetime: "%B %-d, %Y at %-I:%M %p",
      date: "%B %-d, %Y",
      short_date: "%b %-d, %Y",
      short_datetime: "%b %-d, %-I:%M %p",
      time: "%-I:%M %p",
      month_year: "%B %Y",
      weekday_date: "%a, %b %-d"
    },
    "de" => %{
      datetime: "%-d. %B %Y, %H:%M",
      date: "%-d. %B %Y",
      short_date: "%-d. %b %Y",
      short_datetime: "%-d. %b, %H:%M",
      time: "%H:%M",
      month_year: "%B %Y",
      weekday_date: "%a, %-d. %b"
    },
    "es" => %{
      datetime: "%-d de %B de %Y, %H:%M",
      date: "%-d de %B de %Y",
      short_date: "%-d %b %Y",
      short_datetime: "%-d %b, %H:%M",
      time: "%H:%M",
      month_year: "%B de %Y",
      weekday_date: "%a %-d %b"
    },
    "fr" => %{
      datetime: "%-d %B %Y à %H:%M",
      date: "%-d %B %Y",
      short_date: "%-d %b %Y",
      short_datetime: "%-d %b à %H:%M",
      time: "%H:%M",
      month_year: "%B %Y",
      weekday_date: "%a %-d %b"
    },
    "pt" => %{
      datetime: "%-d de %B de %Y às %H:%M",
      date: "%-d de %B de %Y",
      short_date: "%-d de %b de %Y",
      short_datetime: "%-d de %b, %H:%M",
      time: "%H:%M",
      month_year: "%B de %Y",
      weekday_date: "%a, %-d %b"
    },
    "ja" => Map.put(@ja_zh, :short_date, "%Y/%m/%d"),
    "zh" => Map.put(@ja_zh, :short_date, "%Y/%-m/%-d")
  }

  @type style ::
          :datetime | :date | :short_date | :short_datetime | :time | :month_year | :weekday_date
  @type value :: DateTime.t() | NaiveDateTime.t() | Date.t() | nil

  @doc """
  Sets the current process's viewer timezone.
  """
  @spec put_timezone(String.t()) :: :ok
  def put_timezone(timezone) when is_binary(timezone) do
    Process.put(@key, timezone)
    :ok
  end

  @doc """
  The current process's viewer timezone, or `"Etc/UTC"` when none was put.
  """
  @spec timezone() :: String.t()
  def timezone, do: Process.get(@key, @default)

  @doc """
  The styles `format/2` accepts.
  """
  @spec styles() :: [style()]
  def styles, do: @styles

  @doc """
  Formats `value` in `style` for the process timezone and the current locale.

  Returns `""` for `nil`. See `format/3`.
  """
  @spec format(value(), style()) :: String.t()
  def format(value, style), do: format(value, style, timezone())

  @doc """
  Formats `value` in `style` for an explicit `zone`, ignoring the process zone.

  A `zone` the tz database does not accept falls back to `"Etc/UTC"`. A `Date`
  is never shifted, `:datetime` or `:time` on a `Date` render its `:date` text,
  and `:short_datetime` its `:short_date` text, since a `Date` carries no time.
  """
  @spec format(value(), style(), term()) :: String.t()
  def format(nil, style, _zone) when style in @styles, do: ""

  def format(%Date{} = date, style, _zone) when style in [:datetime, :time],
    do: strftime(date, pattern(:date))

  def format(%Date{} = date, :short_datetime, _zone),
    do: strftime(date, pattern(:short_date))

  def format(%Date{} = date, style, _zone) when style in @styles,
    do: strftime(date, pattern(style))

  def format(%NaiveDateTime{} = naive, style, zone) when style in @styles,
    do: naive |> DateTime.from_naive!("Etc/UTC") |> format(style, zone)

  def format(%DateTime{} = datetime, style, zone) when style in @styles,
    do: datetime |> shift(zone) |> strftime(pattern(style))

  @doc """
  The full local date and time with the zone abbreviation, e.g.
  `"November 10, 2026 at 6:56 PM EST"`, for a tooltip.

  A `Date` renders its `:date` text with no zone; `nil` renders `""`.
  """
  @spec format_full(value()) :: String.t()
  def format_full(value), do: format_full(value, timezone())

  @doc """
  `format_full/1` for an explicit `zone`.
  """
  @spec format_full(value(), term()) :: String.t()
  def format_full(nil, _zone), do: ""
  def format_full(%Date{} = date, zone), do: format(date, :date, zone)

  def format_full(%NaiveDateTime{} = naive, zone),
    do: naive |> DateTime.from_naive!("Etc/UTC") |> format_full(zone)

  def format_full(%DateTime{} = datetime, zone),
    do: datetime |> shift(zone) |> strftime(pattern(:datetime) <> " %Z")

  @doc """
  The ISO 8601 form of `value` in UTC, whatever the locale or zone, for a
  machine-readable `datetime` attribute.

  A `Date` renders as `"2026-11-10"`; `nil` renders `""`.
  """
  @spec utc_iso8601(value()) :: String.t()
  def utc_iso8601(nil), do: ""
  def utc_iso8601(%Date{} = date), do: Date.to_iso8601(date)

  def utc_iso8601(%NaiveDateTime{} = naive),
    do: naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  def utc_iso8601(%DateTime{} = datetime),
    do: datetime |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()

  # Only a zone `Timezone.parse_timezone/1` accepts reaches `shift_zone!/2`, so
  # the shift cannot fail; anything else is treated as UTC.
  defp shift(datetime, zone), do: DateTime.shift_zone!(datetime, resolve_zone(zone))

  defp resolve_zone(zone) do
    case Timezone.parse_timezone(zone) do
      {:ok, valid} -> valid
      :error -> @default
    end
  end

  defp pattern(style) do
    locale_patterns = Map.get(@patterns, Gettext.get_locale(KanbanWeb.Gettext), @patterns["en"])
    Map.fetch!(locale_patterns, style)
  end

  defp strftime(value, pattern) do
    Calendar.strftime(value, pattern,
      month_names: &Names.month/1,
      abbreviated_month_names: &Names.month_abbr/1,
      day_of_week_names: &Names.weekday/1,
      abbreviated_day_of_week_names: &Names.weekday_abbr/1,
      am_pm_names: &Names.am_pm/1
    )
  end
end
