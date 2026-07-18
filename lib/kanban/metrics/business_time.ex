defmodule Kanban.Metrics.BusinessTime do
  @moduledoc """
  Weekend-aware elapsed-time arithmetic for the board metrics.

  The metrics pages offer an "exclude weekends" filter. When it is enabled the
  raw elapsed time between two timestamps is reduced by the portion of the
  interval that actually falls on a Saturday or Sunday.

  The subtraction is an *overlap* calculation, not a day count: only the
  seconds of the interval that lie inside a weekend day are removed. An earlier
  implementation subtracted a full 24 hours for every weekend calendar date the
  interval touched, which collapsed any weekend-touching interval shorter than
  the subtracted total to exactly zero — a Saturday-evening to Monday-morning
  wait of 36 real hours reported as `0`.

  Weekend boundaries are evaluated in UTC, matching how the metrics queries
  store and compare timestamps.
  """

  @weekend_days [6, 7]
  @seconds_per_day 86_400

  @doc """
  Returns the seconds between `start_time` and `end_time`, minus any part of
  the interval that falls on a weekend.

  Both arguments accept a `DateTime` or a `NaiveDateTime` (interpreted as UTC).
  The result is clamped at zero so out-of-order timestamps can never produce a
  negative duration.

  ## Examples

      # Saturday 20:00 -> Monday 08:00: 36 elapsed hours, 28 of them on the
      # weekend, leaving 8 business hours.
      iex> Kanban.Metrics.BusinessTime.business_seconds(
      ...>   ~U[2026-01-31 20:00:00Z],
      ...>   ~U[2026-02-02 08:00:00Z]
      ...> )
      28800

      # No weekend touched: the full interval survives.
      iex> Kanban.Metrics.BusinessTime.business_seconds(
      ...>   ~U[2026-02-03 09:00:00Z],
      ...>   ~U[2026-02-04 09:00:00Z]
      ...> )
      86400

  """
  def business_seconds(start_time, end_time) do
    start_dt = to_utc_datetime(start_time)
    end_dt = to_utc_datetime(end_time)

    total_seconds = DateTime.diff(end_dt, start_dt, :second)

    max(total_seconds - weekend_seconds(start_dt, end_dt), 0)
  end

  # The seconds of [start_dt, end_dt] that land on a Saturday or Sunday. A
  # reversed or zero-length interval overlaps nothing; the caller's clamp
  # handles the sign.
  defp weekend_seconds(start_dt, end_dt) do
    if DateTime.compare(start_dt, end_dt) == :lt do
      start_dt
      |> weekend_dates(end_dt)
      |> Enum.reduce(0, fn date, acc -> acc + overlap_seconds(date, start_dt, end_dt) end)
    else
      0
    end
  end

  defp weekend_dates(start_dt, end_dt) do
    start_dt
    |> DateTime.to_date()
    |> Date.range(DateTime.to_date(end_dt))
    |> Enum.filter(&(Date.day_of_week(&1) in @weekend_days))
  end

  # How much of a single weekend day the interval covers.
  defp overlap_seconds(date, start_dt, end_dt) do
    day_start = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    day_end = DateTime.add(day_start, @seconds_per_day, :second)

    overlap_start = latest(start_dt, day_start)
    overlap_end = earliest(end_dt, day_end)

    max(DateTime.diff(overlap_end, overlap_start, :second), 0)
  end

  defp latest(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)
  defp earliest(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)

  @doc """
  Normalizes a `NaiveDateTime` (assumed UTC) or `DateTime` to a UTC `DateTime`.
  """
  def to_utc_datetime(%DateTime{} = dt), do: dt
  def to_utc_datetime(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")
end
