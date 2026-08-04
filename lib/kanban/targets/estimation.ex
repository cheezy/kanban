defmodule Kanban.Targets.Estimation do
  @moduledoc """
  Pure estimated-completion math for delivery targets.

  Sibling of `Kanban.Targets.Status` and `Kanban.Targets.Progress`: no Ecto,
  no clock reads — `now` is always injected by `Kanban.Targets` at its impure
  boundary. `Kanban.Targets.Queries.list_completed_lead_times_by_board/1`
  fetches one query's worth of history for a whole set of boards, and
  `Kanban.Targets.Progress` re-pools a single target's own boards out of that
  by-board map before handing the sample here; this module turns it into a
  date.

  ## The estimate

  `estimated_completion_date/3` projects when a target's remaining work will
  finish: the 50th percentile (median) of the historical lead-time sample
  (seconds from task creation to completion), times the remaining task count,
  added to `now` **as an instant**. The answer is the calendar day that instant
  lands on, read in the anchor's own zone.

  Projecting an instant rather than a whole number of days is the whole of
  D212. The old math added `ceil(seconds / 86_400)` *days* to a `Date`, which
  rounded any non-zero fraction of a day up to a full one — so a target with a
  single remaining task could never estimate as today, however early in the day
  it was and however short the median. A 35/36 target at 08:00 with a four-hour
  median read *tomorrow*. Anchoring on an instant makes the same input read
  today, and makes a projection that genuinely runs past local midnight read
  tomorrow for the right reason.

  Three properties are preserved deliberately:

    * **Never earlier than the math supports.** The seconds product is rounded
      up (`ceil/1`) at *second* granularity, not day granularity, so sub-second
      slack can only ever push the estimate later. `round/1` here would be
      wrong: it can shave up to half a second off and, against a projection
      landing exactly on local midnight, pull the whole estimate back a
      calendar day.
    * **A projection landing exactly at local midnight belongs to the NEW day.**
      The local day is the half-open interval `[00:00:00, 24:00:00)`, which is
      what `DateTime.to_date/1` yields with no special-casing. Finishing at
      exactly 00:00:00 on the 18th is not finishing on the 17th.
    * **A degenerate all-zero-lead sample yields `now`'s own date** — `ceil(0)`
      is `0`, so the projection does not move. Documented, not special-cased,
      exactly as before.

  Adding absolute seconds to a zoned `DateTime` re-resolves the UTC offset, so a
  multi-day projection across a DST transition shifts by one wall-clock hour.
  That is correct absolute-time semantics — "N × 24h of work from now" — and it
  is `DateTime`'s behaviour, not this module's. It does mean the module reads
  the configured time-zone database (`Calendar.get_time_zone_database/0`); that
  is a *config* read, not a clock read, and the module stays deterministic for a
  given `now`.

  ## When there is no estimate

  `nil` means "render nothing", and it must propagate untouched:

    * An empty sample — `Kanban.Metrics.Calculations.percentile/2` returns
      `nil` for `[]`, and that `nil` is passed through, never defaulted to `0`
      (a `0` would render a same-day estimate instead of suppressing it).
    * `remaining == 0` — either nothing was ever planned (a `0/0` childless
      target) or everything credited is done while a goal is still open;
      `now`'s own date would be a meaningless promise either way. The
      all-goals-complete gate lives upstream in `Kanban.Targets.Progress`,
      which skips the sample query entirely.

  `Calculations.percentile/2` is deliberately reused across contexts — it is a
  pure math utility, and duplicating it here would only invite drift.
  """

  alias Kanban.Metrics.Calculations

  @doc """
  The projected completion date for `remaining` tasks paced by the 50th
  percentile (median) of `lead_times_seconds`, counted forward from the instant
  `now` and reported as the calendar day the projection lands on in `now`'s own
  zone.

  Returns `nil` when `remaining` is `0` or the sample is empty — see the
  moduledoc for why `nil` must never be coerced to a date.
  """
  @spec estimated_completion_date([number()], non_neg_integer(), DateTime.t()) :: Date.t() | nil
  def estimated_completion_date(_lead_times_seconds, 0, %DateTime{}), do: nil

  def estimated_completion_date(lead_times_seconds, remaining, %DateTime{} = now)
      when is_list(lead_times_seconds) and is_integer(remaining) and remaining > 0 do
    case Calculations.percentile(lead_times_seconds, 50) do
      nil ->
        nil

      p50_seconds ->
        now
        |> DateTime.add(ceil(remaining * p50_seconds), :second)
        |> DateTime.to_date()
    end
  end
end
