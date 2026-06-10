defmodule Kanban.Archives do
  @moduledoc """
  Read-only context for the workspace Archive view.

  A task is "archived" when its `:archived_at` field is set. The
  `:archive_reason` field categorizes why; legacy archived rows have
  `nil` and are treated as `:completed` for filtering and stats purposes.

  All public functions are scope-aware: when a `Kanban.Accounts.Scope`
  is passed, results are filtered to tasks on boards the scoped user can
  access via `Kanban.Boards.BoardUser` membership. When `nil`, the full
  set is returned.

  This module is read-only by design — writes (archive, unarchive) live
  on `Kanban.Tasks.AgentWorkflow` and `Kanban.Tasks.Lifecycle`. Mirrors
  the structure of `Kanban.Agents` and `Kanban.Reviews`.
  """

  import Ecto.Query, warn: false

  alias Kanban.Queries.BoardScope
  alias Kanban.Repo
  alias Kanban.Tasks.Task

  # Archive-reason buckets surfaced by archive_stats/1. The `:wontdo`
  # and `:duplicate` rows are aggregated under one key because the UI
  # collapses them into a single "won't do / duplicate" pill.
  @wontdo_duplicate_reasons [:wontdo, :duplicate]

  @doc """
  Returns the list of archived tasks, newest first.

  `:column` and `:archived_by` are preloaded so callers can render the
  board chip and the "archived by" avatar without N+1 lookups.

  ## Options

    * `:reason` — one of `:completed`, `:duplicate`, `:wontdo`,
      `:deferred`, `:cancelled`. Filters the result to rows whose
      `archive_reason` matches. `nil` (the default) returns every
      reason. When the value is `:completed`, legacy rows with a `nil`
      `archive_reason` are included because the Archive view treats
      them as `:completed`.
    * `:scope` — a `Kanban.Accounts.Scope.t/0`. Limits results to tasks
      on boards the scoped user is a member of. When `nil`, all archived
      tasks are returned.
  """
  @spec list_archived(keyword()) :: [Task.t()]
  def list_archived(opts \\ []) do
    Task
    |> archived_query()
    |> apply_reason(Keyword.get(opts, :reason))
    |> BoardScope.apply_board_scope(Keyword.get(opts, :scope))
    |> order_by([t], desc: t.archived_at)
    |> preload([:column, :archived_by])
    |> Repo.all()
  end

  @doc """
  Board-scoped variant of `list_archived/1` used by `KanbanWeb.ArchiveLive`.

  Preloads everything `KanbanWeb.ArchiveRow` reads —
  `:column`, `:assigned_to`, `:archived_by`, `:duplicate_of`, `:parent`
  — so the LiveView never has to touch Ecto / `Repo.preload` directly.

  Results are ordered newest first.
  """
  @spec list_archived_for_board(integer()) :: [Task.t()]
  def list_archived_for_board(board_id) when is_integer(board_id) do
    Task
    |> archived_query()
    |> where([_t, column: c], c.board_id == ^board_id)
    |> order_by([t], desc: t.archived_at)
    |> preload([:column, :assigned_to, :archived_by, :duplicate_of, :parent])
    |> Repo.all()
  end

  @doc """
  Returns archive counters for the header band of the Archive view.

  Buckets:

    * `:total` — every archived task in the scope
    * `:completed` — `archive_reason` is `:completed` OR `nil` (legacy)
    * `:cancelled` — `archive_reason` is `:cancelled`
    * `:wontdo_duplicate` — `archive_reason` is `:wontdo` OR `:duplicate`
    * `:deferred` — `archive_reason` is `:deferred`
    * `:avg_cycle_minutes` — integer average of `:time_spent_minutes`
      across archived tasks with a non-nil value, or `nil` when none.

  ## Options

    * `:scope` — see `list_archived/1`.
  """
  @spec archive_stats(keyword()) :: %{
          total: non_neg_integer(),
          completed: non_neg_integer(),
          cancelled: non_neg_integer(),
          wontdo_duplicate: non_neg_integer(),
          deferred: non_neg_integer(),
          avg_cycle_minutes: non_neg_integer() | nil
        }
  def archive_stats(opts \\ []) do
    rows =
      Task
      |> archived_query()
      |> BoardScope.apply_board_scope(Keyword.get(opts, :scope))
      |> select([t], %{reason: t.archive_reason, minutes: t.time_spent_minutes})
      |> Repo.all()

    build_stats(rows)
  end

  @doc """
  Board-scoped variant of `archive_stats/1`. Returns the same map shape
  as `archive_stats/1` but counts only tasks archived on the given
  board, so the strip totals stay consistent with the per-board row
  list returned by `list_archived_for_board/1`.
  """
  @spec archive_stats_for_board(integer()) :: %{
          total: non_neg_integer(),
          completed: non_neg_integer(),
          cancelled: non_neg_integer(),
          wontdo_duplicate: non_neg_integer(),
          deferred: non_neg_integer(),
          avg_cycle_minutes: non_neg_integer() | nil
        }
  def archive_stats_for_board(board_id) when is_integer(board_id) do
    rows =
      Task
      |> archived_query()
      |> where([_t, column: c], c.board_id == ^board_id)
      |> select([t], %{reason: t.archive_reason, minutes: t.time_spent_minutes})
      |> Repo.all()

    build_stats(rows)
  end

  defp build_stats(rows) do
    %{
      total: length(rows),
      completed: count_completed(rows),
      cancelled: count_reason(rows, :cancelled),
      wontdo_duplicate: count_reasons(rows, @wontdo_duplicate_reasons),
      deferred: count_reason(rows, :deferred),
      avg_cycle_minutes: avg_minutes(rows)
    }
  end

  # --- Query helpers --------------------------------------------------------

  defp archived_query(query) do
    from(t in query,
      join: c in assoc(t, :column),
      as: :column,
      where: not is_nil(t.archived_at)
    )
  end

  defp apply_reason(query, nil), do: query

  defp apply_reason(query, :completed) do
    # The Archive view treats nil-reason legacy rows as :completed.
    where(query, [t], t.archive_reason == :completed or is_nil(t.archive_reason))
  end

  defp apply_reason(query, reason) when is_atom(reason) do
    where(query, [t], t.archive_reason == ^reason)
  end

  # --- archive_stats helpers ------------------------------------------------

  defp count_completed(rows) do
    Enum.count(rows, fn %{reason: r} -> r in [:completed, nil] end)
  end

  defp count_reason(rows, reason) do
    Enum.count(rows, fn %{reason: r} -> r == reason end)
  end

  defp count_reasons(rows, reasons) do
    Enum.count(rows, fn %{reason: r} -> r in reasons end)
  end

  defp avg_minutes(rows) do
    minutes =
      rows
      |> Enum.map(& &1.minutes)
      |> Enum.reject(&is_nil/1)

    case minutes do
      [] -> nil
      values -> values |> Enum.sum() |> div(length(values))
    end
  end
end
