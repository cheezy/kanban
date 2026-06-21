defmodule Kanban.Timezone do
  @moduledoc """
  Shared local-timezone helpers for date-sensitive calculations.

  Stored task timestamps are UTC, but surfaces that bucket by calendar day
  (the `/agents` and `/metrics` pages) must anchor each day boundary to the
  *viewer's* local wall clock instead of UTC — otherwise late-evening work west
  of UTC rolls into the next UTC day and lands on the wrong bar/row.

  These two primitives are the single source of truth for that conversion. Both
  fall back to the UTC date when the zone is unknown/empty, so a malformed
  browser-supplied zone can never crash a caller.
  """

  @doc """
  The viewer's local calendar date "today" in `timezone`.

  Falls back to `Date.utc_today/0` when the zone is unknown or empty.
  """
  @spec local_today(String.t()) :: Date.t()
  def local_today(timezone) do
    case DateTime.now(timezone) do
      {:ok, now} -> DateTime.to_date(now)
      {:error, _reason} -> Date.utc_today()
    end
  end

  @doc """
  The local calendar date of a stored UTC timestamp `dt` in `timezone`, so a
  counter's day boundary matches the user's wall clock.

  Falls back to the timestamp's UTC date when the zone is unknown.
  """
  @spec local_date(DateTime.t(), String.t()) :: Date.t()
  def local_date(%DateTime{} = dt, timezone) do
    case DateTime.shift_zone(dt, timezone) do
      {:ok, shifted} -> DateTime.to_date(shifted)
      {:error, _reason} -> DateTime.to_date(dt)
    end
  end

  @doc """
  The UTC `DateTime` of midnight on `date` in `timezone` — the local day's start
  expressed as the instant to compare against UTC-stored timestamps in a query.

  DST-safe: an ambiguous or gap midnight resolves to the first valid instant; an
  unknown zone falls back to midnight UTC.
  """
  @spec start_of_local_day(Date.t(), String.t()) :: DateTime.t()
  def start_of_local_day(%Date{} = date, timezone) do
    case DateTime.new(date, ~T[00:00:00], timezone) do
      {:ok, local_midnight} -> DateTime.shift_zone!(local_midnight, "Etc/UTC")
      {:ambiguous, first, _second} -> DateTime.shift_zone!(first, "Etc/UTC")
      {:gap, just_before, _just_after} -> DateTime.shift_zone!(just_before, "Etc/UTC")
      {:error, _reason} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    end
  end

  @doc """
  The UTC `DateTime` of the last second (23:59:59) of `date` in `timezone` — the
  local day's end as an instant to compare against UTC-stored timestamps.

  DST-safe: an ambiguous end-of-day resolves to the later instant and a gap to
  the instant after it (both keep the whole local day inside the boundary); an
  unknown zone falls back to 23:59:59 UTC.
  """
  @spec end_of_local_day(Date.t(), String.t()) :: DateTime.t()
  def end_of_local_day(%Date{} = date, timezone) do
    case DateTime.new(date, ~T[23:59:59], timezone) do
      {:ok, local_eod} -> DateTime.shift_zone!(local_eod, "Etc/UTC")
      {:ambiguous, _first, last} -> DateTime.shift_zone!(last, "Etc/UTC")
      {:gap, _just_before, just_after} -> DateTime.shift_zone!(just_after, "Etc/UTC")
      {:error, _reason} -> DateTime.new!(date, ~T[23:59:59], "Etc/UTC")
    end
  end
end
