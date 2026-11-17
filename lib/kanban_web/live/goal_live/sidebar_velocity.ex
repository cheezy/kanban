defmodule KanbanWeb.GoalLive.SidebarVelocity do
  @moduledoc """
  Builds the throughput sparkline shown in the goal page's right sidebar.

  Counts child completions per time bucket. The unit adapts to the goal's
  age: hourly while the earliest signal (the goal's claim, its insert, or
  any child completion) is within the last 24 hours, daily after that.

  The number of buckets follows the goal's age too, so a young goal is not
  padded with bars from before it existed: one bucket per unit of age, plus
  the current one, capped at 12 and never fewer than 2 (a single point
  draws no line in `KanbanWeb.PulseSparkline`).

  Extracted from `KanbanWeb.GoalLive.Show` (D426), which merges the result
  into the sidebar's metrics map.
  """

  alias KanbanWeb.LocalTime

  @max_buckets 12
  @min_buckets 2

  @doc """
  Returns the sparkline keys of the sidebar metrics map:

    * `:sparkline_data` — completions per bucket, oldest first
    * `:sparkline_label` — the caption range, from the first bucket's start to `now`
    * `:sparkline_unit` — `:hour` or `:day`
    * `:sparkline_count` — the number of buckets
  """
  @spec build(map(), [map()], DateTime.t()) :: map()
  def build(goal, children, now \\ DateTime.utc_now()) do
    earliest = earliest_signal(goal, children)
    unit = bucket_unit(earliest, now)
    count = bucket_count(earliest, unit, now)

    %{
      sparkline_data: bucket_indexes(completed_at_list(children), now, bucket_size(unit), count),
      sparkline_label: bucket_label(unit, count, now),
      sparkline_unit: unit,
      sparkline_count: count
    }
  end

  @doc """
  How many `unit` buckets span the time from `earliest` to `now`: the whole
  units elapsed plus the current one, clamped to 2..12 (a future
  `earliest` therefore gets the 2-bucket minimum). With no signal at all the
  full 12 are used.
  """
  @spec bucket_count(DateTime.t() | nil, :hour | :day, DateTime.t()) :: pos_integer()
  def bucket_count(nil, _unit, _now), do: @max_buckets

  def bucket_count(%DateTime{} = earliest, unit, now) do
    (div(DateTime.diff(now, earliest, :second), bucket_size(unit)) + 1)
    |> min(@max_buckets)
    |> max(@min_buckets)
  end

  defp completed_at_list(children) do
    children
    |> Enum.map(&Map.get(&1, :completed_at))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_datetime/1)
  end

  defp earliest_signal(goal, children) do
    candidates =
      [Map.get(goal, :claimed_at), Map.get(goal, :inserted_at) | completed_at_list(children)]
      |> Enum.map(&to_datetime/1)
      |> Enum.reject(&is_nil/1)

    Enum.min(candidates, DateTime, fn -> nil end)
  end

  defp bucket_unit(nil, _now), do: :hour

  defp bucket_unit(%DateTime{} = earliest, now) do
    if DateTime.diff(now, earliest, :second) <= 86_400, do: :hour, else: :day
  end

  defp bucket_size(:hour), do: 3600
  defp bucket_size(:day), do: 86_400

  # For each completion, the bucket index is floor((now - completed_at) / size).
  # Index 0 is the most recent bucket. We then reverse so the oldest sits on
  # the left of the sparkline (which is how PulseSparkline reads its data).
  defp bucket_indexes(completions, now, size_seconds, count) do
    counts = List.duplicate(0, count)

    Enum.reduce(completions, counts, fn dt, acc ->
      idx = div(DateTime.diff(now, dt, :second), size_seconds)
      if idx in 0..(count - 1), do: List.update_at(acc, idx, &(&1 + 1)), else: acc
    end)
    |> Enum.reverse()
  end

  # The caption starts where the oldest bucket starts.
  defp bucket_label(unit, count, now) do
    from = DateTime.add(now, -count * bucket_size(unit), :second)
    range_label(from, now, label_style(unit))
  end

  defp label_style(:hour), do: :time
  defp label_style(:day), do: :short_date

  # Both ends shift to the viewer's zone and follow the UI language: the
  # zone and locale are per-process, set by the on_mount hooks before mount/3.
  defp range_label(from, to, style),
    do: "#{LocalTime.format(from, style)} — #{LocalTime.format(to, style)}"

  defp to_datetime(%DateTime{} = dt), do: dt
  defp to_datetime(%NaiveDateTime{} = dt), do: DateTime.from_naive!(dt, "Etc/UTC")
  defp to_datetime(_), do: nil
end
