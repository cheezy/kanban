defmodule Kanban.Targets.Status do
  @moduledoc """
  Derives a delivery target's status at read time — never a stored column.

  A `Kanban.Targets.DeliveryTarget` groups member goals toward a dated
  outcome. Rather than persisting a status that could drift from the goals,
  this module computes one of four values on demand from an explicit snapshot
  of member-goal progress plus a caller-supplied `today`:

    * `:complete`  — every member goal is complete.
    * `:missed`    — `today` is strictly past the `target_date` and the target
      is not complete.
    * `:at_risk`   — the share of goal *work* completed lags the share of
      *calendar time* elapsed (from the target's creation date to its
      `target_date`) by more than `@lag_threshold`.
    * `:on_track`  — everything else.

  ## Purity

  This module is pure: `derive/3` takes `today` as a required `Date`. It never
  calls `Date.utc_today/0`. Anchoring "now" is the caller's job (mirroring the
  `_from`/`today` split in `Kanban.Agents.Metrics`), which keeps the derivation
  deterministic and trivially testable. A future task wires this into
  `Kanban.Targets` by building the `goal_progress` list from already board-
  scoped data; this module implements only the pure computation.

  ## Input shape

  `derive/3` receives one `t:goal_progress/0` map per member goal:

      %{
        completed_children: non_neg_integer(),
        total_children: non_neg_integer(),
        goal_complete?: boolean()
      }

  `goal_complete?` mirrors the stored `goal.status == :completed` flag — the
  "every goal complete" check trusts that stored field and does NOT re-derive
  completion from the goal's children.

  ## Work share (child-fraction vs goal-fraction)

  "Share of goal work completed" is ambiguous: it could mean the fraction of
  *goals* done, or the fraction of *child tasks* done. This module resolves
  that in favour of child-task work:

      work_share = sum(completed_children) / sum(total_children)

  across all member goals, so a large goal counts for more than a small one.

  A childless goal (`total_children == 0`) would contribute nothing to either
  sum, so it is treated as **one unit of work**, done iff its stored status is
  complete: it adds `goal_complete? && 1 || 0` to the numerator and `1` to the
  denominator. Consequently the denominator is always `>= 1` for a non-empty
  list, so the work-share division cannot hit zero.

  ## Elapsed calendar share

      created_on    = DateTime.to_date(target.inserted_at)
      elapsed_share = Date.diff(today, created_on) / Date.diff(target_date, created_on)

  clamped to `[0.0, 1.0]` — a `today` before creation reads as `0.0`, and a
  `today` at/after the target reads as `1.0`.

  ## Lag threshold

  `@lag_threshold` is `0.15` (15 percentage points). A target is `:at_risk`
  only when work completion trails calendar elapsed by MORE than this cushion:

      at_risk?  when  elapsed_share - completed_share > @lag_threshold

  The comparison is strictly greater — a gap of exactly the threshold is
  `:on_track`, not `:at_risk`. 15 points tolerates the normal front-loaded
  ramp of a delivery effort (planning, setup, and dependency work land before
  visible task completion) without crying wolf, while still flagging a target
  that has fallen meaningfully behind its calendar.

  ### Float noise

  `elapsed_share - completed_share` is IEEE-754 subtraction, so an intended gap
  of `0.15` can compute as `0.15000000000000002` (e.g. `0.6 - 0.45`). Comparing
  that raw value against `0.15` would spuriously flip an exactly-on-threshold
  target to `:at_risk`. The gap is therefore rounded to 9 decimal places before
  the comparison — far finer than any meaningful lag, but coarse enough to
  erase last-bit subtraction noise so the boundary is exact.

  ## Edge cases

    * **No member goals** → `:on_track`. A target with no goals is neutral, not
      vacuously `:complete` (an empty target has delivered nothing).
    * **Degenerate window** — if `Date.diff(target_date, created_on) <= 0`
      (target created on or after its own target date), the elapsed-share
      division is undefined, so the `:at_risk` math is skipped and the result
      is `:on_track`. This branch is only reachable when the target is not
      complete and `today` is not past the target date (otherwise `:complete`
      or `:missed` already won).

  ## Branch precedence

  `derive/3` evaluates, in order: empty list → all complete → past target date
  → lagging → else. Order matters: an all-complete target past its date is
  `:complete` (completion beats missed), and `:missed` is checked before the
  `:at_risk` lag math.
  """

  alias Kanban.Targets.DeliveryTarget

  @typedoc "Progress snapshot for a single member goal."
  @type goal_progress :: %{
          completed_children: non_neg_integer(),
          total_children: non_neg_integer(),
          goal_complete?: boolean()
        }

  @type status :: :complete | :missed | :at_risk | :on_track

  # A target is at risk only when completed work trails elapsed calendar time
  # by MORE than this fraction (15 percentage points). See the moduledoc.
  @lag_threshold 0.15

  # Decimal places the lag is rounded to before the threshold comparison, to
  # erase IEEE-754 subtraction noise (0.6 - 0.45 == 0.15000000000000002).
  @lag_precision 9

  @doc """
  Derives the status of `target` from a per-goal `goal_progress` snapshot and an
  explicit `today`.

  See the moduledoc for the full semantics, the work-share definition, the
  `0.15` lag threshold, and the empty-list / degenerate-window edge cases.
  """
  @spec derive(DeliveryTarget.t(), [goal_progress()], Date.t()) :: status()
  def derive(%DeliveryTarget{} = target, goal_progress, %Date{} = today) do
    cond do
      goal_progress == [] -> :on_track
      all_complete?(goal_progress) -> :complete
      past_target?(target, today) -> :missed
      lagging?(target, goal_progress, today) -> :at_risk
      true -> :on_track
    end
  end

  # Every member goal complete, per the stored goal_complete? flag (never
  # re-derived from children). Only reached for a non-empty list.
  defp all_complete?(goal_progress), do: Enum.all?(goal_progress, & &1.goal_complete?)

  # today strictly after the target date.
  defp past_target?(%DeliveryTarget{target_date: target_date}, today) do
    Date.compare(today, target_date) == :gt
  end

  # Work completion trails calendar elapsed by more than @lag_threshold. Guards
  # the degenerate creation->target window (<= 0 days) so the elapsed-share
  # division is never undefined; a degenerate window is treated as not lagging.
  defp lagging?(target, goal_progress, today) do
    created_on = DateTime.to_date(target.inserted_at)
    window_days = Date.diff(target.target_date, created_on)

    if window_days <= 0 do
      false
    else
      gap = elapsed_share(created_on, today, window_days) - work_share(goal_progress)
      Float.round(gap, @lag_precision) > @lag_threshold
    end
  end

  # Fraction of the creation->target calendar window elapsed as of `today`,
  # clamped to [0.0, 1.0]. Caller guarantees window_days > 0.
  defp elapsed_share(created_on, today, window_days) do
    clamp(Date.diff(today, created_on) / window_days)
  end

  # Fraction of child-task work completed across member goals, with a childless
  # goal counting as one unit done iff its stored status is complete. The
  # denominator is always >= 1 for a non-empty list; the guard is defensive.
  defp work_share(goal_progress) do
    {done, total} =
      Enum.reduce(goal_progress, {0, 0}, fn gp, {done, total} ->
        {num, denom} = work_units(gp)
        {done + num, total + denom}
      end)

    if total <= 0, do: 0.0, else: done / total
  end

  # A childless goal is one unit of work, done iff complete; otherwise the goal
  # contributes its completed/total child counts directly.
  defp work_units(%{total_children: 0, goal_complete?: complete?}), do: {unit(complete?), 1}
  defp work_units(%{completed_children: completed, total_children: total}), do: {completed, total}

  defp unit(true), do: 1
  defp unit(false), do: 0

  defp clamp(value) when value < 0.0, do: 0.0
  defp clamp(value) when value > 1.0, do: 1.0
  defp clamp(value), do: value
end
