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
  """
  @spec day_range(pos_integer(), String.t()) :: [Date.t()]
  def day_range(window_days, timezone) do
    today = Timezone.local_today(timezone)

    (-window_days + 1)..0
    |> Enum.map(&Date.add(today, &1))
  end

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
