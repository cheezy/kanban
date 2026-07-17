defmodule Kanban.Targets.Estimation do
  @moduledoc """
  Pure estimated-completion math for delivery targets.

  Sibling of `Kanban.Targets.Status` and `Kanban.Targets.Progress`: no Ecto,
  no clock reads — `today` is always injected by `Kanban.Targets` at its impure
  boundary. `Kanban.Targets.Queries.list_completed_lead_times/1` fetches the
  historical sample; this module turns it into a date.

  ## The estimate

  `estimated_completion_date/3` projects when a target's remaining work will
  finish: the 25th percentile of the historical lead-time sample (seconds from
  task creation to completion), times the remaining task count, added to
  `today`. Days are rounded UP (`ceil/1`) so the estimate never promises an
  earlier date than the math supports. A degenerate all-zero-lead sample
  therefore yields `today` itself — documented, not special-cased.

  ## When there is no estimate

  `nil` means "render nothing", and it must propagate untouched:

    * An empty sample — `Kanban.Metrics.Calculations.percentile/2` returns
      `nil` for `[]`, and that `nil` is passed through, never defaulted to `0`
      (a `0` would render a same-day estimate instead of suppressing it).
    * `remaining == 0` — either nothing was ever planned (a `0/0` childless
      target) or everything credited is done while the derived status lags;
      `today + 0` would be a meaningless promise either way. The `:complete`
      status gate lives upstream in `Kanban.Targets.Progress`, which skips the
      sample query entirely.

  `Calculations.percentile/2` is deliberately reused across contexts — it is a
  pure math utility, and duplicating it here would only invite drift.
  """

  alias Kanban.Metrics.Calculations

  @seconds_per_day 86_400

  @doc """
  The projected completion date for `remaining` tasks paced by the 25th
  percentile of `lead_times_seconds`, counted from `today`.

  Returns `nil` when `remaining` is `0` or the sample is empty — see the
  moduledoc for why `nil` must never be coerced to a date.
  """
  @spec estimated_completion_date([number()], non_neg_integer(), Date.t()) :: Date.t() | nil
  def estimated_completion_date(_lead_times_seconds, 0, %Date{}), do: nil

  def estimated_completion_date(lead_times_seconds, remaining, %Date{} = today)
      when is_list(lead_times_seconds) and is_integer(remaining) and remaining > 0 do
    case Calculations.percentile(lead_times_seconds, 25) do
      nil -> nil
      p25_seconds -> Date.add(today, ceil(remaining * p25_seconds / @seconds_per_day))
    end
  end
end
