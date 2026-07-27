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
    * `:at_risk`   — EITHER the share of goal *work* completed lags the share
      of *calendar time* elapsed (from the target's creation date to its
      `target_date`) by more than `@lag_threshold`, OR the caller-supplied
      estimated completion date falls strictly after the `target_date`. Either
      condition alone is sufficient; neither requires the other.
    * `:on_track`  — everything else.

  ## Purity

  This module is pure: `derive/4` takes `today` as a required `Date`. It never
  calls `Date.utc_today/0`. Anchoring "now" is the caller's job (mirroring the
  `_from`/`today` split in `Kanban.Agents.Metrics`), which keeps the derivation
  deterministic and trivially testable. The estimated completion date is
  injected exactly the same way: this module never computes an estimate, never
  queries a lead-time sample, and never reads a clock — `Kanban.Targets.Progress`
  computes the estimate at its impure boundary and passes it down.

  ## Input shape

  `derive/4` receives one `t:goal_progress/0` map per member goal:

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

  ## Estimated completion slip (D182)

  The fourth argument is the target's estimated completion date, `Date.t()` or
  `nil`. An estimate strictly after the `target_date` is a *slip*, and a slip
  raises `:at_risk` on its own — it is the earliest concrete signal a target
  will be late, and it fires even when the work share is high enough to
  suppress the lag check.

    * `nil` means "this caller does not estimate" and reproduces the pre-D182
      behaviour exactly, so a caller that supplies none sees no change.
    * The test is `Date.compare(estimate, target_date) == :gt` — strictly
      after, the same strictness `past_target?/2` and the lag threshold use, so
      an estimate landing exactly ON the target date is not a slip.
    * Every badge-rendering read path supplies a real estimate, from one
      batched sample (see the "Estimated completion" and "Batched lead-time
      sample" sections of `Kanban.Targets.Progress`). The archive gate is the
      one caller that passes `nil`, deliberately — it reads only `:complete`.
    * Because an estimate is always `today + n` for `n >= 0`, a slip can only
      be observed while `today <= target_date` — that is, on a target that is
      not already `:missed`. No extra guard is needed for that.

  ## Edge cases

    * **No member goals** → `:on_track`. A target with no goals is neutral, not
      vacuously `:complete` (an empty target has delivered nothing). The empty
      arm precedes both `:at_risk` causes, so such a target stays `:on_track`
      even if a slipping estimate is supplied — and `Progress` never produces
      that pair anyway, because a childless target's remaining count is `0` and
      its estimate is therefore `nil`.
    * **Degenerate window** — if `Date.diff(target_date, created_on) <= 0`
      (target created on or after its own target date), the elapsed-share
      division is undefined, so the lag *math* is skipped. Such a target is
      `:on_track` unless its estimate slips: the slip check is independent of
      the creation→target window, so it still fires here. This branch is only
      reachable when the target is not complete and `today` is not past the
      target date (otherwise `:complete` or `:missed` already won).
    * **Estimate exactly on the target date** → not a slip, so the target
      derives whatever it would with no estimate at all.

  ## Branch precedence

  `derive/4` evaluates, in order: empty list → all complete → past target date
  → (lagging OR estimate slip) → else. The order is deliberate: an all-complete
  target past its date is still `:complete` (completion beats missed, and beats
  a slipping estimate); `:missed` is still checked before either `:at_risk`
  cause, so a target already past its date is missed, not at risk; and the two
  `:at_risk` causes share a SINGLE arm as a disjunction rather than occupying
  two arms, because they are independent sufficient conditions for the same
  verdict. Keeping them in one arm is also what lets an estimate slip raise
  `:at_risk` when the window is degenerate and `lagging?/3` short-circuits to
  `false` before its division.
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
  Derives the status of `target` from a per-goal `goal_progress` snapshot, an
  explicit `today`, and the target's estimated completion date.

  `estimate` defaults to `nil`, which means "this caller does not estimate" and
  reproduces the pre-D182 result exactly. A non-nil estimate strictly after the
  `target_date` raises `:at_risk` on its own — see the moduledoc's "Estimated
  completion slip" section.

  See the moduledoc for the full semantics, the work-share definition, the
  `0.15` lag threshold, and the empty-list / degenerate-window edge cases.
  """
  @spec derive(DeliveryTarget.t(), [goal_progress()], Date.t(), Date.t() | nil) :: status()
  def derive(%DeliveryTarget{} = target, goal_progress, %Date{} = today, estimate \\ nil) do
    cond do
      goal_progress == [] -> :on_track
      all_complete?(goal_progress) -> :complete
      past_target?(target, today) -> :missed
      lagging?(target, goal_progress, today) or slipped?(estimate, target.target_date) -> :at_risk
      true -> :on_track
    end
  end

  @doc """
  Whether `estimate` is a *slip* — strictly after `target_date` (D182).

  Public because the badge and the three surfaces that explain it must make
  exactly this comparison, never their own copy of it: `KanbanWeb.TargetsStrip`,
  `KanbanWeb.TargetProgressHeader`, and `KanbanWeb.TargetRiskExplainer` all call
  it so a target can never be badged `:at_risk` for a slip the explanation does
  not recognise (W1952). D123 and D182 were both defects of exactly that shape.

  `nil` on either side — no estimate available, or a caller that does not
  estimate — is never a slip, which is what reproduces the pre-D182 behaviour
  for callers that supply none. The comparison is strictly `:gt`, so an estimate
  landing exactly ON the target date is not a slip.
  """
  @spec slipped?(Date.t() | nil, Date.t() | nil) :: boolean()
  def slipped?(%Date{} = estimate, %Date{} = target_date) do
    Date.compare(estimate, target_date) == :gt
  end

  def slipped?(_estimate, _target_date), do: false

  # Every member goal complete, per the stored goal_complete? flag (never
  # re-derived from children). Only reached for a non-empty list.
  defp all_complete?(goal_progress), do: Enum.all?(goal_progress, & &1.goal_complete?)

  # today strictly after the target date.
  defp past_target?(%DeliveryTarget{target_date: target_date}, today) do
    Date.compare(today, target_date) == :gt
  end

  # Work completion trails calendar elapsed by more than @lag_threshold. Guards
  # the degenerate creation->target window (<= 0 days) so the elapsed-share
  # division is never undefined; a degenerate window is treated as not lagging —
  # but it can still be :at_risk via slipped?/2, so do not "fix" this guard by
  # hoisting it into derive/4.
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
