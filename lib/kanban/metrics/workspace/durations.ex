defmodule Kanban.Metrics.Workspace.Durations do
  @moduledoc """
  The duration statistics behind the workspace completed-task metrics.

  Extracted from `Kanban.Metrics.Workspace.CompletedTasks` (W1743) to keep that
  module under the size guideline once weekend-aware durations landed. This
  module owns the three per-task intervals the workspace reports — cycle time
  (claim to completion), lead time (creation to completion), and review wait
  (completion to review) — and the median/percentile roll-ups over them.

  Every function takes an `exclude_weekends?` flag. When it is true the weekend
  *portion* of each interval is subtracted via
  `Kanban.Metrics.BusinessTime.business_seconds/2` rather than the task being
  dropped: a task claimed on Friday evening and completed Monday morning keeps
  its weekday hours. `business_seconds/2` clamps at zero, so an interval falling
  entirely inside a weekend collapses to 0 rather than going negative.

  Tasks missing the timestamps an interval needs yield `nil`, which the roll-ups
  reject before averaging — a task completed without ever being claimed has no
  cycle time but still has a lead time.
  """

  alias Kanban.Metrics.BusinessTime
  alias Kanban.Metrics.Calculations

  @doc "Median cycle time in whole minutes across `tasks`; 0 when none qualify."
  @spec median_cycle_minutes([map()], boolean()) :: non_neg_integer()
  def median_cycle_minutes(tasks, exclude_weekends?) do
    tasks
    |> Enum.map(&cycle_minutes(&1, exclude_weekends?))
    |> Enum.reject(&is_nil/1)
    |> Calculations.median()
    |> round_or_zero()
  end

  @doc """
  The per-day lead statistic. p50 (the median) is deliberate: it matches the KPI
  strip's lead-time cell and makes the lead and cycle series — which both report
  a median — directly comparable.
  """
  @spec median_lead_minutes([map()], boolean()) :: non_neg_integer()
  def median_lead_minutes(tasks, exclude_weekends?),
    do: percentile_lead_minutes(tasks, 50, exclude_weekends?)

  @doc "The `p`th-percentile lead time in whole minutes; 0 when none qualify."
  @spec percentile_lead_minutes([map()], number(), boolean()) :: non_neg_integer()
  def percentile_lead_minutes(tasks, p, exclude_weekends?) do
    tasks
    |> Enum.map(&lead_minutes(&1, exclude_weekends?))
    |> Enum.reject(&is_nil/1)
    |> Calculations.percentile(p)
    |> round_or_zero()
  end

  @doc "Median review wait in whole minutes; 0 when no task needed review."
  @spec median_review_wait_minutes([map()], boolean()) :: non_neg_integer()
  def median_review_wait_minutes(tasks, exclude_weekends?) do
    tasks
    |> Enum.map(&review_wait_minutes(&1, exclude_weekends?))
    |> Enum.reject(&is_nil/1)
    |> Calculations.median()
    |> round_or_zero()
  end

  @doc "One task's cycle time in whole minutes, or nil when it was never claimed."
  @spec cycle_minutes(map(), boolean()) :: non_neg_integer() | nil
  def cycle_minutes(%{claimed_at: %DateTime{} = c, completed_at: %DateTime{} = d}, exclude?) do
    elapsed_minutes(c, d, exclude?)
  end

  def cycle_minutes(_task, _exclude?), do: nil

  @doc "One task's lead time in whole minutes, or nil when it is not complete."
  @spec lead_minutes(map(), boolean()) :: non_neg_integer() | nil
  # `BusinessTime.business_seconds/2` normalizes a NaiveDateTime to UTC itself,
  # so the raw `inserted_at` is handed straight to it.
  def lead_minutes(%{inserted_at: %NaiveDateTime{} = i, completed_at: %DateTime{} = d}, exclude?) do
    elapsed_minutes(i, d, exclude?)
  end

  def lead_minutes(_task, _exclude?), do: nil

  @doc "One task's review wait in whole minutes, or nil when review did not apply."
  @spec review_wait_minutes(map(), boolean()) :: non_neg_integer() | nil
  def review_wait_minutes(
        %{needs_review: true, completed_at: %DateTime{} = c, reviewed_at: %DateTime{} = r},
        exclude?
      ) do
    elapsed_minutes(c, r, exclude?)
  end

  def review_wait_minutes(_task, _exclude?), do: nil

  # The single interval rule behind all three durations. `business_seconds/2`
  # already clamps at zero, so the `max(0)` guard is only needed on the plain
  # path (where an out-of-order pair would otherwise go negative).
  defp elapsed_minutes(start_time, end_time, true) do
    start_time |> BusinessTime.business_seconds(end_time) |> div(60)
  end

  defp elapsed_minutes(start_time, end_time, false) do
    start_dt = to_utc(start_time)
    end_dt = to_utc(end_time)

    end_dt |> DateTime.diff(start_dt, :second) |> max(0) |> div(60)
  end

  defp to_utc(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")
  defp to_utc(%DateTime{} = datetime), do: datetime

  defp round_or_zero(nil), do: 0
  defp round_or_zero(value) when is_number(value), do: round(value)
end
