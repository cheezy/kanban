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
end
