defmodule KanbanWeb.MetricsLive.Helpers do
  @moduledoc """
  Pure-function utility module for metrics LiveView modules: formatters,
  param parsers, date-window math, and statistical helpers (averages,
  trend lines, daily-time aggregation).

  This module is intentionally separate from `KanbanWeb.MetricsLive.Base`.
  `Base` is the LiveView lifecycle mixin (macro-injected `mount/3`,
  `handle_params/3`, `handle_event/3` plus socket-aware helpers); this
  module is the stateless utility layer. `Base` depends on `Helpers`;
  the reverse is not true. See the moduledoc on
  `KanbanWeb.MetricsLive.Base` for the full rationale.

  Date-window and completion-grouping helpers take an optional `timezone`
  (IANA string, default `"Etc/UTC"`) so the board metrics surfaces can bucket
  by the viewer's local calendar day. The local-day conversion is delegated to
  `Kanban.Timezone`; `"Etc/UTC"` reproduces the prior UTC behavior exactly.
  """

  use Gettext, backend: KanbanWeb.Gettext

  alias Kanban.Timezone

  @doc """
  The translated label for a time-range atom, or `nil` when the atom is not one
  of the five known ranges.

  Returning `nil` rather than a default is deliberate: the two board export
  modules disagree about what an unrecognized range should read as — the PDF
  says "Custom Range" while the Excel export falls back to the 30-day label —
  and that difference is pre-existing behavior this function must not silently
  unify. Callers supply their own fallback with `||`, so the five shared labels
  live in one place and cannot drift while each caller keeps its own tail.
  """
  def time_range_label(:today), do: gettext("Today")
  def time_range_label(:last_7_days), do: gettext("Last 7 Days")
  def time_range_label(:last_30_days), do: gettext("Last 30 Days")
  def time_range_label(:last_90_days), do: gettext("Last 90 Days")
  def time_range_label(:all_time), do: gettext("All Time")
  def time_range_label(_other), do: nil

  def format_time(%Decimal{} = seconds) do
    seconds
    |> Decimal.to_float()
    |> format_time()
  end

  def format_time(seconds) when is_number(seconds) do
    hours = seconds / 3600

    cond do
      hours < 1 -> "#{Float.round(hours * 60, 1)}m"
      hours < 24 -> "#{Float.round(hours, 1)}h"
      true -> "#{Float.round(hours / 24, 1)}d"
    end
  end

  def format_time(_), do: "N/A"

  def format_time_hours(hours) when is_number(hours) do
    # Promote integers so Float.round/2 never raises; identity for floats.
    hours_float = hours / 1

    cond do
      hours_float < 1 -> "#{Float.round(hours_float * 60, 1)}m"
      hours_float < 24 -> "#{Float.round(hours_float, 1)}h"
      true -> "#{Float.round(hours_float / 24, 1)}d"
    end
  end

  def format_time_hours(_), do: "N/A"

  def format_datetime(nil), do: "N/A"

  def format_datetime(datetime) do
    Calendar.strftime(datetime, "%b %d, %Y %I:%M %p")
  end

  def format_date(nil), do: "N/A"

  def format_date(date) do
    Calendar.strftime(date, "%b %d, %Y")
  end

  def format_time_only(nil), do: "N/A"

  def format_time_only(datetime) do
    Calendar.strftime(datetime, "%I:%M %p")
  end

  # Local-calendar-day windows anchored to the viewer's `timezone` (default
  # "Etc/UTC" for back-compat): `:today` anchors to the viewer's local midnight,
  # and `:last_7_days` includes the last 7 calendar days (today + 6 prior), each
  # starting at 00:00:00 LOCAL time, returned as the equivalent UTC instant for
  # the Ecto where-clause filter. Filtering on calendar days rather than exact
  # hours is what users expect from "last week" — see throughput_test.exs
  # "filters by calendar days, not exact hours".
  def get_start_date(time_range, timezone \\ "Etc/UTC")

  def get_start_date(:today, timezone), do: local_midnight_days_ago(0, timezone)
  def get_start_date(:last_7_days, timezone), do: local_midnight_days_ago(6, timezone)
  def get_start_date(:last_30_days, timezone), do: local_midnight_days_ago(29, timezone)
  def get_start_date(:last_90_days, timezone), do: local_midnight_days_ago(89, timezone)
  def get_start_date(:all_time, _timezone), do: ~U[2020-01-01 00:00:00Z]
  def get_start_date(_, timezone), do: local_midnight_days_ago(29, timezone)

  # The UTC instant of local midnight `days` ago in `timezone`. For "Etc/UTC"
  # this is exactly midnight UTC `days` ago (unchanged from the prior behavior).
  defp local_midnight_days_ago(days, timezone) do
    timezone
    |> Timezone.local_today()
    |> Date.add(-days)
    |> Timezone.start_of_local_day(timezone)
  end

  # D112: match against the fixed set of valid ranges rather than
  # String.to_existing_atom/1, which returned ANY existing atom. The result
  # flows into the export content-disposition filename, so constraining it to
  # this five-member set by construction closes that latent allow-list gap.
  def parse_time_range("today"), do: :today
  def parse_time_range("last_7_days"), do: :last_7_days
  def parse_time_range("last_30_days"), do: :last_30_days
  def parse_time_range("last_90_days"), do: :last_90_days
  def parse_time_range("all_time"), do: :all_time
  def parse_time_range(_time_range), do: :last_30_days

  def parse_agent_name(nil), do: nil
  def parse_agent_name(""), do: nil
  def parse_agent_name(agent_name) when is_binary(agent_name), do: agent_name

  def parse_exclude_weekends(nil), do: false
  def parse_exclude_weekends(""), do: false
  def parse_exclude_weekends("true"), do: true
  def parse_exclude_weekends("false"), do: false
  def parse_exclude_weekends(_), do: false

  @window_options [7, 14, 30, 90]
  @default_window_days 14

  @doc """
  The trailing-window lengths (in days) the workspace metrics surfaces offer.

  Mirrors `Kanban.Metrics.Workspace`'s own allow-list. Kept in sync by
  `parse_window_days/1`'s tests rather than by a shared attribute, since the
  context deliberately re-validates every option it is handed.
  """
  def window_options, do: @window_options

  @doc """
  The window length used when none is supplied or the supplied one is rejected.
  """
  def default_window_days, do: @default_window_days

  @doc """
  Parse a window length from a param or an assign, falling back to
  `default_window_days/0`.

  This is a param-parsing convenience, NOT a security boundary: it exists so
  callers hold a resolved value they can render (a chart label, an export
  filename) without echoing raw input. `Kanban.Metrics.Workspace` re-validates
  `:window_days` against the same allow-list on every read, so a value that
  slipped past here still cannot reach a query.
  """
  def parse_window_days(value) when is_integer(value) and value in @window_options, do: value

  def parse_window_days(value) when is_binary(value) do
    case Integer.parse(value) do
      {days, ""} when days in @window_options -> days
      _ -> @default_window_days
    end
  end

  def parse_window_days(_value), do: @default_window_days

  def extract_time_seconds(%Decimal{} = seconds), do: Decimal.to_float(seconds)
  def extract_time_seconds(seconds) when is_number(seconds), do: seconds
  def extract_time_seconds(_), do: 0.0

  def calculate_average([]), do: 0.0
  def calculate_average(values), do: Enum.sum(values) / length(values)

  def get_max_time([]), do: 0

  def get_max_time(daily_times) do
    daily_times
    |> Enum.map(& &1.average_hours)
    |> Enum.max(fn -> 0 end)
  end

  @doc """
  Least-squares linear regression over a daily metrics series.

  Returns `%{slope: slope, intercept: intercept}`, or `nil` for a series
  with fewer than two points (no line can be fitted through one point).

  `value_key` names the field holding each day's value, so one regression
  serves series in different units — the board charts pass the default
  `:average_hours`, the workspace cycle time chart passes `:minutes`. It is
  a field name rather than an arbitrary accessor function, so a caller can
  only read fields of the series it already supplied.
  """
  def calculate_trend_line(daily_times, value_key \\ :average_hours)

  def calculate_trend_line([], _value_key), do: nil
  def calculate_trend_line([_single], _value_key), do: nil

  def calculate_trend_line(daily_times, value_key) do
    n = length(daily_times)
    {sum_x, sum_y, sum_xy, sum_x_squared} = calculate_regression_sums(daily_times, value_key)

    slope = calculate_slope(n, sum_x, sum_y, sum_xy, sum_x_squared)
    intercept = calculate_intercept(n, sum_x, sum_y, slope)

    %{slope: slope, intercept: intercept}
  end

  defp calculate_regression_sums(daily_times, value_key) do
    daily_times
    |> Enum.with_index()
    |> Enum.reduce({0.0, 0.0, 0.0, 0.0}, fn entry, sums ->
      accumulate_regression_sums(entry, sums, value_key)
    end)
  end

  defp accumulate_regression_sums({day, index}, {sx, sy, sxy, sx2}, value_key) do
    x = index * 1.0
    y = Map.fetch!(day, value_key) * 1.0
    {sx + x, sy + y, sxy + x * y, sx2 + x * x}
  end

  defp calculate_slope(n, sum_x, sum_y, sum_xy, sum_x_squared) do
    (n * sum_xy - sum_x * sum_y) / (n * sum_x_squared - sum_x * sum_x)
  end

  defp calculate_intercept(n, sum_x, sum_y, slope) do
    (sum_y - slope * sum_x) / n
  end

  # `completed_at` is a UTC `DateTime` (the Task schema's `:utc_datetime`), so
  # `Timezone.local_date/2` shifts it straight into the viewer's zone. Callers
  # with a `NaiveDateTime` source must normalize to UTC first (see wait_time.ex).
  def group_tasks_by_completion_date(tasks, timezone \\ "Etc/UTC") do
    tasks
    |> Enum.group_by(fn task -> Timezone.local_date(task.completed_at, timezone) end)
    |> Enum.sort_by(fn {date, _tasks} -> date end, {:desc, Date})
    |> Enum.map(fn {date, day_tasks} ->
      {date, Enum.sort_by(day_tasks, & &1.completed_at, {:desc, DateTime})}
    end)
  end

  def calculate_daily_times(tasks, time_field, timezone \\ "Etc/UTC") do
    tasks
    |> Enum.group_by(fn task -> Timezone.local_date(task.completed_at, timezone) end)
    |> Enum.map(&daily_time_entry(&1, time_field))
    |> Enum.sort_by(& &1.date, Date)
  end

  defp daily_time_entry({date, day_tasks}, time_field) do
    times = Enum.map(day_tasks, &extract_time_seconds(Map.get(&1, time_field)))
    average_seconds = calculate_average(times)
    %{date: date, average_hours: average_seconds / 3600}
  end
end
