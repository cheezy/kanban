defmodule Kanban.Metrics.Workspace.Windows do
  @moduledoc """
  Shared local-day window helpers for the workspace metric reads.

  Every workspace series is bucketed by the viewer's local calendar day. These
  two helpers convert a trailing `window_days` count and an IANA `timezone` into
  the concrete `Date` range and UTC query boundaries the completed-task and
  cumulative-flow modules both consume, so the local-day logic lives in exactly
  one place.
  """

  alias Kanban.Timezone

  @doc """
  The viewer's local calendar days for the trailing window, oldest-to-newest:
  the last `window_days` days ending on the local "today".

  When `exclude_weekends?` is true, Saturdays and Sundays are dropped from the
  result. The window still spans the same `window_days` calendar days — only the
  weekend days are removed, so the returned list is shorter than `window_days`
  rather than reaching further back. Every workspace series buckets over this
  list, so filtering here is what keeps the cycle, lead, throughput, and
  cumulative-flow series aligned on one shared set of days.
  """
  @spec day_range(pos_integer(), String.t(), boolean()) :: [Date.t()]
  def day_range(window_days, timezone, exclude_weekends? \\ false) do
    today = Timezone.local_today(timezone)

    (-window_days + 1)..0
    |> Enum.map(&Date.add(today, &1))
    |> reject_weekends(exclude_weekends?)
  end

  @doc """
  The equal-length window immediately preceding `day_range/3` — the days from
  `2 * window_days - 1` back through `window_days` back, oldest-to-newest.

  This is the comparison window the KPI deltas are measured against. It needs its
  own range (rather than reusing `day_range/3`'s length) because with weekends
  excluded the two windows can hold different numbers of weekdays: any 7 or 14
  consecutive days hold exactly 5 or 10, but a 30-day window holds 20 to 22 and a
  90-day window 64 to 66 depending on where it starts. Dividing both windows'
  counts by the current window's weekday count would skew the delta percentage.
  """
  @spec previous_day_range(pos_integer(), String.t(), boolean()) :: [Date.t()]
  def previous_day_range(window_days, timezone, exclude_weekends? \\ false) do
    today = Timezone.local_today(timezone)

    (-(2 * window_days) + 1)..-window_days//1
    |> Enum.map(&Date.add(today, &1))
    |> reject_weekends(exclude_weekends?)
  end

  defp reject_weekends(dates, false), do: dates

  defp reject_weekends(dates, true),
    do: Enum.reject(dates, &(Date.day_of_week(&1) in [6, 7]))

  @doc """
  The UTC instant of the start of the local day `days_back` days before the
  viewer's local "today" — the query boundary for a trailing local-day window.
  """
  @spec local_day_start(non_neg_integer(), String.t()) :: DateTime.t()
  def local_day_start(days_back, timezone) do
    timezone
    |> Timezone.local_today()
    |> Date.add(-days_back)
    |> Timezone.start_of_local_day(timezone)
  end
end
