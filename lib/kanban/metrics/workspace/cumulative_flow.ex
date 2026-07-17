defmodule Kanban.Metrics.Workspace.CumulativeFlow do
  @moduledoc """
  The workspace cumulative-flow read behind the `/metrics` page. Extracted from
  `Kanban.Metrics.Workspace` (W1737) to keep that façade under the module-size
  guideline.

  `snapshots/3` returns one snapshot per local day in the trailing window, each
  with integer counts for `:backlog`, `:ready`, `:doing`, `:review`, and
  `:done`. The façade resolves scope and options, then hands this module the
  already-resolved `board_ids`, `window_days`, and `timezone`.

  ### Cumulative-flow approximation

  No daily snapshot table exists. Each per-day snapshot is reconstructed
  by classifying every visible task by its timestamp state at end-of-day:

  | Bucket    | Rule (at end-of-day D) |
  |-----------|-------------------------|
  | `:backlog`  | `inserted_at <= D` and `claimed_at IS NULL` |
  | `:ready`    | always 0 (no schema distinction between :open and "ready"; reserved for a future snapshot table) |
  | `:doing`    | `claimed_at <= D` and (`completed_at` is `nil` or `> D`) |
  | `:review`   | `completed_at <= D`, `needs_review`, and (`reviewed_at` is `nil` or `> D`) |
  | `:done`     | `reviewed_at <= D` OR (`completed_at <= D` and not `needs_review`) |

  Archived tasks (`archived_at <= D`) are excluded from every bucket.

  The snapshots are computed without ever loading full task rows: a
  projection returns only the seven fields the rules above read, and the
  stable done history (never-archived, claimed, no-review tasks completed
  before the window starts) is collapsed into a single `COUNT` added to
  every day's done bucket, so only tasks whose state can still change
  within the window are fetched row by row. The bucket rules — this table
  — remain the single source of truth; the output is identical.
  """

  import Ecto.Query, warn: false

  alias Kanban.Metrics.Workspace.Windows
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias Kanban.Timezone

  @doc """
  Returns daily cumulative-flow snapshots (oldest-to-newest) for the trailing
  window. Each snapshot has integer counts for `:backlog`, `:ready`, `:doing`,
  `:review`, and `:done`, plus its `:date`. See the `@moduledoc` for the
  per-state approximation rules.
  """
  @spec snapshots([integer()], pos_integer(), String.t()) :: [
          %{
            date: Date.t(),
            backlog: non_neg_integer(),
            ready: non_neg_integer(),
            doing: non_neg_integer(),
            review: non_neg_integer(),
            done: non_neg_integer()
          }
        ]
  def snapshots(board_ids, window_days, timezone) do
    window_start = Windows.local_day_start(window_days - 1, timezone)
    tasks = cfd_relevant_tasks(board_ids, window_start)
    baseline_done = cfd_done_baseline(board_ids, window_start)

    window_days
    |> Windows.day_range(timezone)
    |> Enum.map(&cfd_snapshot(tasks, baseline_done, &1, timezone))
  end

  @doc "The zero cumulative-flow snapshots (all buckets 0) for the trailing window."
  @spec empty_snapshots(pos_integer(), String.t()) :: [map()]
  def empty_snapshots(window_days, timezone) do
    window_days
    |> Windows.day_range(timezone)
    |> Enum.map(&zero_flow_snapshot/1)
  end

  defp zero_flow_snapshot(date) do
    %{date: date, backlog: 0, ready: 0, doing: 0, review: 0, done: 0}
  end

  # The cumulative-flow rows whose bucket can still change within the window, or
  # that were archived (archived tasks need per-day exclusion and must never be
  # collapsed — see cfd_done_baseline/2). Projects ONLY the seven fields the
  # classification reads — never full `%Task{}` structs — cutting the transferred
  # payload by roughly two orders of magnitude. This is the exact De Morgan
  # complement of the collapsible set in cfd_done_baseline/2, so every visible
  # task is counted by exactly one of the two queries. Goals are intentionally
  # NOT filtered out — cumulative flow counts them exactly as before (W579).
  defp cfd_relevant_tasks(board_ids, %DateTime{} = window_start) do
    Task
    |> join(:inner, [t], c in assoc(t, :column))
    |> where([t, c], c.board_id in ^board_ids)
    |> where(
      [t, _c],
      not is_nil(t.archived_at) or is_nil(t.claimed_at) or t.needs_review == true or
        is_nil(t.completed_at) or t.completed_at >= ^window_start
    )
    |> select([t, _c], %{
      inserted_at: t.inserted_at,
      claimed_at: t.claimed_at,
      completed_at: t.completed_at,
      reviewed_at: t.reviewed_at,
      needs_review: t.needs_review,
      archived_at: t.archived_at,
      type: t.type
    })
    |> Repo.all()
  end

  # Collapses the stable done history into one COUNT instead of fetching it row by
  # row. A task qualifies only when it is provably in the `done` bucket — and no
  # other bucket — on every day of the window: never archived (so it is visible
  # every day and needs no per-day exclusion), claimed (so it is never counted as
  # backlog), not needing review, and completed strictly before the window starts
  # (so `done_at?` holds from the first day on via the completed-and-not-reviewed
  # path). Each such task contributes exactly +1 to every day's done count. Any
  # task not matching this stays row-level in cfd_relevant_tasks/2, so the
  # per-day snapshots remain identical to the full-table implementation.
  defp cfd_done_baseline(board_ids, %DateTime{} = window_start) do
    Task
    |> join(:inner, [t], c in assoc(t, :column))
    |> where([t, c], c.board_id in ^board_ids)
    |> where([t, _c], is_nil(t.archived_at))
    |> where([t, _c], not is_nil(t.claimed_at))
    |> where([t, _c], t.needs_review == false)
    |> where([t, _c], not is_nil(t.completed_at) and t.completed_at < ^window_start)
    |> Repo.aggregate(:count)
  end

  defp cfd_snapshot(tasks, baseline_done, date, timezone) do
    eod = Timezone.end_of_local_day(date, timezone)
    visible = Enum.reject(tasks, &archived_before?(&1, eod))

    visible
    |> cfd_bucket_counts(eod)
    # The collapsed pre-window done tasks (cfd_done_baseline/2) are done on every
    # day of the window, so add their constant count to each day's done bucket.
    |> Map.update!(:done, &(&1 + baseline_done))
    |> Map.put(:date, date)
  end

  defp cfd_bucket_counts(visible, eod) do
    %{
      backlog: Enum.count(visible, &backlog_at?(&1, eod)),
      ready: 0,
      doing: Enum.count(visible, &doing_at?(&1, eod)),
      review: Enum.count(visible, &review_at?(&1, eod)),
      done: Enum.count(visible, &done_at?(&1, eod))
    }
  end

  defp archived_before?(%{archived_at: %DateTime{} = a}, eod),
    do: DateTime.compare(a, eod) != :gt

  defp archived_before?(_, _), do: false

  defp inserted_before?(%{inserted_at: %NaiveDateTime{} = i}, eod) do
    i
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.compare(eod)
    |> Kernel.!=(:gt)
  end

  defp inserted_before?(_, _), do: false

  defp backlog_at?(task, eod) do
    inserted_before?(task, eod) and is_nil(task.claimed_at)
  end

  defp doing_at?(task, eod) do
    claimed_at_or_before?(task, eod) and not completed_at_or_before?(task, eod)
  end

  defp review_at?(task, eod) do
    task.needs_review and completed_at_or_before?(task, eod) and
      not reviewed_at_or_before?(task, eod)
  end

  defp done_at?(task, eod) do
    reviewed_at_or_before?(task, eod) or
      (completed_at_or_before?(task, eod) and not task.needs_review)
  end

  defp claimed_at_or_before?(%{claimed_at: %DateTime{} = dt}, eod),
    do: DateTime.compare(dt, eod) != :gt

  defp claimed_at_or_before?(_, _), do: false

  defp completed_at_or_before?(%{completed_at: %DateTime{} = dt}, eod),
    do: DateTime.compare(dt, eod) != :gt

  defp completed_at_or_before?(_, _), do: false

  defp reviewed_at_or_before?(%{reviewed_at: %DateTime{} = dt}, eod),
    do: DateTime.compare(dt, eod) != :gt

  defp reviewed_at_or_before?(_, _), do: false
end
